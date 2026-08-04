import Foundation
import Network

/// Local bridge for Claude Code hooks. Hook commands POST their stdin JSON
/// to http://127.0.0.1:48620/hook/<EventName>; most events get an instant
/// empty response, while pending permission requests are held open until
/// the user decides in the popover (or a timeout fails open). Bound to
/// loopback only.
@MainActor
final class HookServer: ApprovalResponding {
    /// Whether the local hook bridge is actually accepting connections.
    /// Config detection alone cannot answer this: the entries can be
    /// installed correctly while another process holds the port.
    enum ServerState: Equatable {
        case starting
        case listening
        case unavailable(String)
    }

    static let port: UInt16 = 48620
    /// Held-decision window. Kept under the hook command's own timeout so
    /// the fail-open path is a clean empty response, not a killed process.
    /// Long on purpose: the popover is a glance-later surface, and once
    /// this expires the prompt can only be answered at the terminal.
    static let decisionHold: Duration = .seconds(345)
    /// Largest hook payload accepted. Well above any real Claude or OpenCode
    /// payload, well under the 512 KB read ceiling in `receive`.
    static let maxBodyBytes = 256 * 1024

    private let store: SessionStore
    private var listener: NWListener?

    /// How the held connection expects its decision encoded: Claude hooks
    /// take the PermissionRequest hookSpecificOutput schema, the OpenCode
    /// plugin takes a bare {"decision": "allow"|"deny"}.
    private enum ApprovalKind {
        case claudeHook
        case openCodePlugin
    }

    private struct PendingApproval {
        let kind: ApprovalKind
        let connection: NWConnection
        let respond: (Data) -> Void
        let timeout: Task<Void, Never>
    }
    private var pendingApprovals: [UUID: PendingApproval] = [:]

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: Self.port)!
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.store.hookServerState = .listening
                    case .failed(let error):
                        // Port taken (another SwarmBar, or something else
                        // holding 48620) means remote approve and deny are
                        // dead while the polling monitors still look healthy.
                        self.store.hookServerState = .unavailable(error.localizedDescription)
                    case .cancelled:
                        self.store.hookServerState = .unavailable("Stopped")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            store.hookServerState = .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.dropPending(for: connection) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    /// A held hook client went away (process killed, its own timeout fired,
    /// the prompt was answered at the terminal). The row must stop offering
    /// buttons that can no longer answer anything.
    private func dropPending(for connection: NWConnection) {
        guard let (sessionID, pending) = pendingApprovals
            .first(where: { $0.value.connection === connection })
        else { return }
        pending.timeout.cancel()
        pendingApprovals.removeValue(forKey: sessionID)
        store.clearHookOverride(sessionID: sessionID)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }
                switch Self.parseRequest(buffer) {
                case .complete(let request):
                    self.route(request, connection: connection)
                case .malformed:
                    connection.cancel()
                case .incomplete:
                    if isComplete || buffer.count > 512 * 1024 {
                        connection.cancel()
                    } else {
                        self.receive(connection, buffer: buffer)
                    }
                }
            }
        }
    }

    struct Request {
        var path: String
        var accountLabel: String?
        var body: [String: Any]
    }

    /// Parsing a request either completes, needs more bytes, or is refused.
    /// The distinction matters: `incomplete` means keep receiving, `malformed`
    /// means close the connection rather than route an empty body.
    enum ParseOutcome {
        case complete(Request)
        case incomplete
        case malformed
    }

    static func parseRequest(_ data: Data) -> ParseOutcome {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else { return .malformed }

        var contentLength = 0
        var account: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let raw = line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                // A missing header means an empty body; a present but bogus,
                // negative, or oversized one is a refusal. Data.prefix traps on
                // a negative length, so this guard is load bearing.
                guard let value = Int(raw), value >= 0, value <= Self.maxBodyBytes else {
                    return .malformed
                }
                contentLength = value
            } else if lower.hasPrefix("x-claude-account:") {
                let value = line.dropFirst("x-claude-account:".count)
                    .trimmingCharacters(in: .whitespaces)
                account = value.isEmpty ? nil : value
            }
        }
        let bodyData = data[headerEnd.upperBound...]
        guard bodyData.count >= contentLength else { return .incomplete }
        let bodySlice = Data(bodyData.prefix(contentLength))
        let parsed = (try? JSONSerialization.jsonObject(with: bodySlice)) as? [String: Any]
        // An empty body is legitimate for some events; a non-empty body that is
        // not a JSON object is not, and must not be routed as if it were empty.
        if parsed == nil, !bodySlice.isEmpty { return .malformed }
        return .complete(Request(path: String(parts[1]), accountLabel: account, body: parsed ?? [:]))
    }

    private static func respond(
        _ connection: NWConnection, json: Data, completion: ((Bool) -> Void)? = nil
    ) {
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { error in
            completion?(error == nil)
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func route(_ request: Request, connection: NWConnection) {
        let event = request.path
            .replacingOccurrences(of: "/hook/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let body = request.body
        let rawSessionID = body["session_id"] as? String
        // Claude and Grok use bare UUIDs; Kimi prefixes ("session_<uuid>"),
        // which map through StableID exactly like KimiMonitor's rows.
        let sessionID = rawSessionID.map { UUID(uuidString: $0) ?? StableID.uuid(for: $0) }
        let cwd = body["cwd"] as? String

        func finishEmpty() { Self.respond(connection, json: Data("{}".utf8)) }

        // OpenCode's plugin bridge posts its own event shapes with ses_
        // ids, which map through StableID like the poller's sessions do.
        switch event {
        case "OpenCodePermission":
            handleOpenCodePermission(body, connection: connection)
            return
        case "OpenCodeReplied":
            if let raw = body["sessionID"] as? String {
                let id = StableID.uuid(for: raw)
                cancelPending(sessionID: id)
                store.clearHookOverride(sessionID: id)
            }
            finishEmpty()
            return
        default:
            break
        }

        guard let sessionID, let rawSessionID else { finishEmpty(); return }
        // Grok Build imports Claude-compatible hooks from the shared
        // settings and runs them too, so events arriving here are not
        // necessarily Claude Code's.
        let tool = Self.originTool(rawSessionID: rawSessionID)

        switch event {
        case "PermissionRequest", "PreToolUseHold":
            let command = Self.commandDescription(body)
            store.applyHookEvent(
                sessionID: sessionID, tool: tool,
                status: .waitingApproval(command: command),
                sticky: true, cwd: cwd, accountLabel: request.accountLabel
            )
            // Only Claude honors a held decision response. Kimi's
            // PermissionRequest is observation-only, and Grok 0.2.118
            // treats a timed-out hook as consent, so holding its
            // connection AUTO-APPROVED prompts about 3s in; both get an
            // instant empty response and answer through the terminal.
            if tool == .claudeCode {
                holdForDecision(sessionID: sessionID, kind: .claudeHook, connection: connection)
            } else {
                finishEmpty()
            }

        case "PermissionResult":
            cancelPending(sessionID: sessionID)
            store.clearHookOverride(sessionID: sessionID)
            store.update(id: sessionID) { session in
                if case .waitingApproval = session.status {
                    session.status = .working(activity: "Working…")
                }
            }
            finishEmpty()

        case "PreToolUse":
            store.applyHookEvent(
                sessionID: sessionID, tool: tool,
                status: .runningTool(activity: "Running \(Self.commandDescription(body))"),
                sticky: false, cwd: cwd, accountLabel: request.accountLabel
            )
            finishEmpty()

        case "Stop", "SubagentStop":
            if event == "Stop" {
                store.applyHookEvent(
                    sessionID: sessionID, tool: tool,
                    status: .waitingInput(prompt: ""),
                    sticky: false, cwd: cwd, accountLabel: request.accountLabel
                )
            }
            finishEmpty()

        case "UserPromptSubmit":
            store.applyHookEvent(
                sessionID: sessionID, tool: tool,
                status: .working(activity: "Thinking…"),
                sticky: false, cwd: cwd, accountLabel: request.accountLabel
            )
            finishEmpty()

        case "SessionEnd":
            cancelPending(sessionID: sessionID)
            store.markSessionEnded(sessionID)
            finishEmpty()

        default:
            finishEmpty()
        }
    }

    /// Which tool a hook event came from. Grok Build's Claude-compat layer
    /// runs the same hook commands, and Kimi's own hooks post the same
    /// schema, so check both before assuming Claude Code.
    nonisolated static func originTool(rawSessionID: String) -> AgentTool {
        if rawSessionID.hasPrefix("session_") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let indexes: [(String, AgentTool)] = [
                (".kimi-code/session_index.jsonl", .kimiCode),
                (".bearcode/session_index.jsonl", .bearCode),
            ]
            for (path, tool) in indexes {
                if let text = try? String(
                    contentsOf: home.appendingPathComponent(path), encoding: .utf8),
                   text.contains(rawSessionID) {
                    return tool
                }
            }
        }
        let grokRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok")
        let active = grokRoot.appendingPathComponent("active_sessions.json")
        if let data = try? Data(contentsOf: active),
           let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           entries.contains(where: { ($0["session_id"] as? String) == rawSessionID }) {
            return .grokBuild
        }
        let sessionsDir = grokRoot.appendingPathComponent("sessions")
        if let cwdDirs = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil) {
            for cwdDir in cwdDirs
            where FileManager.default.fileExists(
                atPath: cwdDir.appendingPathComponent(rawSessionID).path) {
                return .grokBuild
            }
        }
        return .claudeCode
    }

    /// A permission.ask payload from the OpenCode plugin: the full
    /// PermissionRequest (id per_..., sessionID ses_..., permission,
    /// patterns, metadata) plus the plugin's project directory. For bash
    /// asks the pattern is the command itself.
    private func handleOpenCodePermission(_ body: [String: Any], connection: NWConnection) {
        guard let rawSessionID = body["sessionID"] as? String else {
            Self.respond(connection, json: Data("{}".utf8))
            return
        }
        let sessionID = StableID.uuid(for: rawSessionID)
        let permission = body["permission"] as? String ?? "tool"
        let metadata = body["metadata"] as? [String: Any]
        let pattern = (metadata?["command"] as? String)
            ?? (body["patterns"] as? [Any])?.first as? String
        let command: String = {
            guard let pattern else { return permission }
            if permission == "bash" {
                let flattened = pattern.replacingOccurrences(of: "\n", with: " ")
                return flattened.count <= 80 ? flattened : String(flattened.prefix(80)) + "…"
            }
            return "\(permission) \(URL(fileURLWithPath: pattern).lastPathComponent)"
        }()
        store.applyHookEvent(
            sessionID: sessionID, tool: .openCode,
            status: .waitingApproval(command: command),
            sticky: true, cwd: body["directory"] as? String, accountLabel: nil
        )
        holdForDecision(sessionID: sessionID, kind: .openCodePlugin, connection: connection)
    }

    private static func commandDescription(_ body: [String: Any]) -> String {
        let toolName = body["tool_name"] as? String ?? "tool"
        let input = body["tool_input"] as? [String: Any]
        if toolName == "Bash", let command = input?["command"] as? String {
            let flattened = command.replacingOccurrences(of: "\n", with: " ")
            return flattened.count <= 80 ? flattened : String(flattened.prefix(80)) + "…"
        }
        if let path = input?["file_path"] as? String {
            return "\(toolName) \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        return toolName
    }

    // MARK: - Pending decisions

    private func holdForDecision(sessionID: UUID, kind: ApprovalKind, connection: NWConnection) {
        // A newer request for the same session supersedes any stale one.
        cancelPending(sessionID: sessionID)
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.decisionHold)
            guard !Task.isCancelled else { return }
            // Fail open: no decision, terminal prompt proceeds as normal.
            // Drop the sticky override too, or the row keeps showing
            // Approve/Deny buttons that can no longer answer anything.
            self?.finishPending(sessionID: sessionID, json: Data("{}".utf8))
            self?.store.clearHookOverride(sessionID: sessionID)
        }
        pendingApprovals[sessionID] = PendingApproval(
            kind: kind,
            connection: connection,
            respond: { json in Self.respond(connection, json: json) },
            timeout: timeout
        )
    }

    private func finishPending(sessionID: UUID, json: Data) {
        guard let pending = pendingApprovals.removeValue(forKey: sessionID) else { return }
        pending.timeout.cancel()
        pending.respond(json)
    }

    private func cancelPending(sessionID: UUID) {
        finishPending(sessionID: sessionID, json: Data("{}".utf8))
    }

    func resolveApproval(sessionID: UUID, allow: Bool) -> Bool {
        guard let pending = pendingApprovals[sessionID] else { return false }
        switch pending.connection.state {
        case .cancelled, .failed:
            dropPending(for: pending.connection)
            return false
        default:
            break
        }
        let decision: [String: Any]
        switch pending.kind {
        case .claudeHook:
            // PermissionRequest decision schema: decision.behavior
            // allow/deny, both verified honored by the CLI.
            let behavior: [String: Any] = allow
                ? ["behavior": "allow"]
                : ["behavior": "deny", "message": "Denied from SwarmBar"]
            decision = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": behavior,
                ],
            ]
        case .openCodePlugin:
            // The plugin relays this through the server's own permission
            // endpoint as respond once/reject.
            decision = ["decision": allow ? "allow" : "deny"]
        }
        let json = (try? JSONSerialization.data(withJSONObject: decision)) ?? Data("{}".utf8)
        pendingApprovals.removeValue(forKey: sessionID)
        pending.timeout.cancel()
        Self.respond(pending.connection, json: json) { [weak self] delivered in
            guard !delivered else { return }
            Task { @MainActor in
                self?.store.noteApprovalDeliveryFailed(sessionID: sessionID)
            }
        }
        store.clearHookOverride(sessionID: sessionID)
        return true
    }
}
