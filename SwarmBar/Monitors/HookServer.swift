import Foundation
import Network

/// Local bridge for Claude Code hooks. Hook commands POST their stdin JSON
/// to http://127.0.0.1:48620/hook/<EventName>; most events get an instant
/// empty response, while pending permission requests are held open until
/// the user decides in the popover (or a timeout fails open). Bound to
/// loopback only.
@MainActor
final class HookServer: ApprovalResponding {
    static let port: UInt16 = 48620
    /// Held-decision window. Kept under the hook command's own timeout so
    /// the fail-open path is a clean empty response, not a killed process.
    static let decisionHold: Duration = .seconds(55)

    private let store: SessionStore
    private var listener: NWListener?

    private struct PendingApproval {
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
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            // Port taken (another SwarmBar?) or sandbox issue; hooks fail
            // open and the polling monitors still work.
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }
                if let request = Self.parseRequest(buffer) {
                    self.route(request, connection: connection)
                } else if isComplete {
                    connection.cancel()
                } else if buffer.count > 512 * 1024 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private struct Request {
        var path: String
        var accountLabel: String?
        var body: [String: Any]
    }

    private static func parseRequest(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else { return nil }

        var contentLength = 0
        var account: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("x-claude-account:") {
                let value = line.dropFirst("x-claude-account:".count)
                    .trimmingCharacters(in: .whitespaces)
                account = value.isEmpty ? nil : value
            }
        }
        let bodyData = data[headerEnd.upperBound...]
        guard bodyData.count >= contentLength else { return nil }
        let body = (try? JSONSerialization.jsonObject(with: Data(bodyData.prefix(contentLength))))
            as? [String: Any] ?? [:]
        return Request(path: String(parts[1]), accountLabel: account, body: body)
    }

    private static func respond(_ connection: NWConnection, json: Data) {
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func route(_ request: Request, connection: NWConnection) {
        let event = request.path
            .replacingOccurrences(of: "/hook/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let body = request.body
        let sessionID = (body["session_id"] as? String).flatMap(UUID.init(uuidString:))
        let cwd = body["cwd"] as? String

        func finishEmpty() { Self.respond(connection, json: Data("{}".utf8)) }

        guard let sessionID else { finishEmpty(); return }

        switch event {
        case "PermissionRequest", "PreToolUseHold":
            let command = Self.commandDescription(body)
            store.applyHookEvent(
                sessionID: sessionID, tool: .claudeCode,
                status: .waitingApproval(command: command),
                sticky: true, cwd: cwd, accountLabel: request.accountLabel
            )
            holdForDecision(sessionID: sessionID, connection: connection)

        case "PreToolUse":
            store.applyHookEvent(
                sessionID: sessionID, tool: .claudeCode,
                status: .runningTool(activity: "Running \(Self.commandDescription(body))"),
                sticky: false, cwd: cwd, accountLabel: request.accountLabel
            )
            finishEmpty()

        case "Stop", "SubagentStop":
            if event == "Stop" {
                store.applyHookEvent(
                    sessionID: sessionID, tool: .claudeCode,
                    status: .waitingInput(prompt: ""),
                    sticky: false, cwd: cwd, accountLabel: request.accountLabel
                )
            }
            finishEmpty()

        case "UserPromptSubmit":
            store.applyHookEvent(
                sessionID: sessionID, tool: .claudeCode,
                status: .working(activity: "Thinking…"),
                sticky: false, cwd: cwd, accountLabel: request.accountLabel
            )
            finishEmpty()

        case "SessionEnd":
            cancelPending(sessionID: sessionID, respondEmpty: true)
            store.clearHookOverride(sessionID: sessionID)
            finishEmpty()

        default:
            finishEmpty()
        }
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

    private func holdForDecision(sessionID: UUID, connection: NWConnection) {
        // A newer request for the same session supersedes any stale one.
        cancelPending(sessionID: sessionID, respondEmpty: true)
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.decisionHold)
            guard !Task.isCancelled else { return }
            // Fail open: no decision, terminal prompt proceeds as normal.
            self?.finishPending(sessionID: sessionID, json: Data("{}".utf8))
        }
        pendingApprovals[sessionID] = PendingApproval(
            respond: { json in Self.respond(connection, json: json) },
            timeout: timeout
        )
    }

    private func finishPending(sessionID: UUID, json: Data) {
        guard let pending = pendingApprovals.removeValue(forKey: sessionID) else { return }
        pending.timeout.cancel()
        pending.respond(json)
    }

    private func cancelPending(sessionID: UUID, respondEmpty: Bool) {
        guard respondEmpty else { return }
        finishPending(sessionID: sessionID, json: Data("{}".utf8))
    }

    func resolveApproval(sessionID: UUID, allow: Bool) -> Bool {
        guard pendingApprovals[sessionID] != nil else { return false }
        // PermissionRequest decision schema: decision.behavior allow/deny.
        // The docs guarantee allow and ask; deny is attempted for real
        // rejection and fails open to the terminal prompt if the CLI
        // rejects it.
        let behavior: [String: Any] = allow
            ? ["behavior": "allow"]
            : ["behavior": "deny", "message": "Denied from SwarmBar"]
        let decision: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": behavior,
            ],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: decision)) ?? Data("{}".utf8)
        finishPending(sessionID: sessionID, json: json)
        store.clearHookOverride(sessionID: sessionID)
        return true
    }
}
