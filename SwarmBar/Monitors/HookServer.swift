import Foundation
import Network

/// Local bridge for Claude Code hooks. Hook commands POST their stdin JSON
/// to http://127.0.0.1:48620/hook/<EventName>; most events get an instant
/// empty response, while pending permission requests are held open until
/// the user decides in the popover (or a timeout fails open). Bound to
/// loopback only. Hook events from remote hosts never reach the socket:
/// each host's RemoteHookRelay hands them to `handleRemote`, which routes
/// them through the same code.
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
    /// nil means the token could not be persisted; run unauthenticated rather
    /// than dropping every hook event.
    private var tokenForRequests: String?

    /// How the held connection expects its decision encoded: Claude hooks
    /// take the PermissionRequest hookSpecificOutput schema, the OpenCode
    /// plugin takes a bare {"decision": "allow"|"deny"}.
    private enum ApprovalKind {
        case claudeHook
        case openCodePlugin
    }

    /// A request held for the popover to answer, from this Mac's socket or
    /// relayed from a host. Neither the routing nor the popover cares which:
    /// both are answered by `respond`, which ends the request.
    private struct PendingApproval {
        let kind: ApprovalKind
        /// Sends the answer. The callback, where given, hears whether the
        /// answer reached the client; a remote reply's fate is not known
        /// here, so a remote responder never calls it.
        let respond: (Data, ((Bool) -> Void)?) -> Void
        /// True once the client can no longer take an answer.
        let isGone: () -> Bool
        let timeout: Task<Void, Never>
        /// Set for a request relayed from a host: the helper's id for it,
        /// and the host it came from.
        let remote: (rid: String, hostID: UUID)?
    }
    private var pendingApprovals: [UUID: PendingApproval] = [:]

    /// How long a relayed request stays answerable. Just past the helper's
    /// own 345 s hold, so a row never offers Approve for a request the
    /// helper has already let go, even if its hook_resolved was lost with
    /// the connection. Injectable so tests need not wait it out.
    private let remoteDecisionHold: Duration

    /// Whose agent state tells local hooks apart. This Mac's home, except
    /// in tests, which must never read a real one.
    private let localHome: URL

    init(
        store: SessionStore, remoteDecisionHold: Duration = .seconds(350),
        localHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.remoteDecisionHold = remoteDecisionHold
        self.localHome = localHome
    }

    func start() {
        // Must exist before any bridge script needs it: hand-installed
        // scripts start looking for the file immediately, not only after a
        // Settings toggle. nil is fail open, not a startup failure.
        tokenForRequests = HookToken.loadOrCreate()
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
                Task { @MainActor [weak self] in self?.dropGonePending() }
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
    private func dropGonePending() {
        for (sessionID, pending) in pendingApprovals where pending.isGone() {
            dropPending(sessionID: sessionID)
        }
    }

    /// Forgets a held request without answering it, and releases its row.
    private func dropPending(sessionID: UUID) {
        guard let pending = pendingApprovals.removeValue(forKey: sessionID) else { return }
        pending.timeout.cancel()
        store.clearHookOverride(sessionID: sessionID)
    }

    private static func isGone(_ connection: NWConnection) -> Bool {
        switch connection.state {
        case .cancelled, .failed: true
        default: false
        }
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
        var token: String?
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
        var token: String?
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
            } else if lower.hasPrefix("x-swarmbar-token:") {
                token = line.dropFirst("x-swarmbar-token:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let bodyData = data[headerEnd.upperBound...]
        guard bodyData.count >= contentLength else { return .incomplete }
        let bodySlice = Data(bodyData.prefix(contentLength))
        let parsed = (try? JSONSerialization.jsonObject(with: bodySlice)) as? [String: Any]
        // An empty body is legitimate for some events; a non-empty body that is
        // not a JSON object is not, and must not be routed as if it were empty.
        if parsed == nil, !bodySlice.isEmpty { return .malformed }
        return .complete(Request(
            path: String(parts[1]), accountLabel: account, token: token, body: parsed ?? [:]))
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

    func route(_ request: Request, connection: NWConnection) {
        func finishEmpty() { Self.respond(connection, json: Data("{}".utf8)) }
        // Only bridges this app installed may change what the popover shows.
        // A wrong or missing token gets the same empty answer a non-session
        // event gets, so a misconfigured bridge fails open rather than hanging.
        if let expected = tokenForRequests, !HookToken.matches(request.token, expected) {
            finishEmpty()
            return
        }
        let event = Self.eventName(fromPath: request.path)
        let body = request.body
        // A hook payload's cwd becomes a session's projectPath, which is handed
        // to the terminal integration. Anything that is not a real directory is
        // dropped rather than displayed.
        let cwd = (body["cwd"] as? String).flatMap {
            TerminalFocuser.isDirectory($0) ? $0 : nil
        }
        let context = HookContext(
            rowID: { $0 },
            // Grok Build imports Claude-compatible hooks from the shared
            // settings and runs them too, so events arriving here are not
            // necessarily Claude Code's.
            tool: { [localHome] in Self.originTool(rawSessionID: $0, home: localHome) },
            cwd: cwd,
            accountLabel: request.accountLabel,
            host: nil,
            // Only Claude honors a held decision response. Kimi's
            // PermissionRequest is observation-only, and Grok 0.2.118
            // treats a timed-out hook as consent, so holding its
            // connection AUTO-APPROVED prompts about 3s in; both get an
            // instant empty response and answer through the terminal.
            mayHold: { kind, tool in kind == .openCodePlugin || tool == .claudeCode },
            release: finishEmpty,
            hold: { [weak self] sessionID, kind in
                self?.holdForDecision(
                    sessionID: sessionID, kind: kind, window: Self.decisionHold,
                    respond: { json, completion in
                        Self.respond(connection, json: json, completion: completion)
                    },
                    isGone: { Self.isGone(connection) },
                    remote: nil)
            })
        dispatch(event: event, body: body, context: context)
    }

    /// "/hook/PermissionRequest" to "PermissionRequest".
    nonisolated static func eventName(fromPath path: String) -> String {
        path.replacingOccurrences(of: "/hook/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// What differs between a hook that reached this Mac's own socket and
    /// one a host's helper relayed. Everything else, which event moves a
    /// row to which status, is the same code for both, so a remote session
    /// can never drift from a local one in how it reads.
    private struct HookContext {
        /// The row id for the id a tool reported, already mapped through
        /// StableID where the tool's ids are not UUIDs.
        let rowID: (UUID) -> UUID
        /// Which tool a session id belongs to, or nil when that cannot be
        /// told, in which case the event is released and shows nothing.
        let tool: (String) -> AgentTool?
        let cwd: String?
        let accountLabel: String?
        /// The host a row created by this event belongs to.
        let host: String?
        /// Whether a request of this kind from this tool may be held.
        let mayHold: (ApprovalKind, AgentTool) -> Bool
        /// Answers {} where something is waiting on an answer.
        let release: () -> Void
        /// Parks the request for the popover to answer.
        let hold: (UUID, ApprovalKind) -> Void
    }

    /// A tool switched off in Settings shows no row, so a held request
    /// from it could only stall its agent for the whole hold with nothing
    /// on screen to answer. It is answered {} at once instead.
    private func mayHold(_ kind: ApprovalKind, _ tool: AgentTool, _ context: HookContext) -> Bool {
        store.isEnabled(tool) && context.mayHold(kind, tool)
    }

    /// Every path through here calls exactly one of `release` and `hold`,
    /// so no request is ever left without an answer.
    private func dispatch(event: String, body: [String: Any], context: HookContext) {
        let rawSessionID = body["session_id"] as? String
        // Claude and Grok use bare UUIDs; Kimi prefixes ("session_<uuid>"),
        // which map through StableID exactly like KimiMonitor's rows.
        let sessionID = rawSessionID.map {
            context.rowID(UUID(uuidString: $0) ?? StableID.uuid(for: $0))
        }
        let cwd = context.cwd
        // The Kimi family puts sessionTitle on every payload. Several rows
        // routinely share a project name, so this is what distinguishes
        // them. Absent for tools that do not send it, which is fine: the
        // store only overwrites when a real value arrives.
        let sessionTitle = (body["sessionTitle"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // OpenCode's plugin bridge posts its own event shapes with ses_
        // ids, which map through StableID like the poller's sessions do.
        switch event {
        case "OpenCodePermission":
            handleOpenCodePermission(body, context: context)
            return
        case "OpenCodeReplied":
            if let raw = body["sessionID"] as? String {
                let id = context.rowID(StableID.uuid(for: raw))
                cancelPending(sessionID: id)
                store.clearHookOverride(sessionID: id)
            }
            context.release()
            return
        default:
            break
        }

        guard let sessionID, let rawSessionID, let tool = context.tool(rawSessionID) else {
            context.release()
            return
        }

        func apply(_ status: SessionStatus, sticky: Bool) {
            store.applyHookEvent(
                sessionID: sessionID, tool: tool, status: status, sticky: sticky,
                cwd: cwd, accountLabel: context.accountLabel, title: sessionTitle,
                host: context.host)
        }

        switch event {
        case "PermissionRequest", "PreToolUseHold":
            apply(.waitingApproval(command: Self.commandDescription(body)), sticky: true)
            if mayHold(.claudeHook, tool, context) {
                context.hold(sessionID, .claudeHook)
            } else {
                context.release()
            }

        case "PermissionResult":
            cancelPending(sessionID: sessionID)
            store.clearHookOverride(sessionID: sessionID)
            leaveApproval(sessionID: sessionID)
            context.release()

        case "PreToolUse":
            apply(.runningTool(activity: "Running \(Self.commandDescription(body))"), sticky: false)
            context.release()

        case "Stop", "SubagentStop":
            if event == "Stop" {
                // Stop only says the turn ended. Let the transcript decide
                // whether it ended with a question or a completed report.
                // Release the working override so the next poll can do so.
                store.clearHookOverride(sessionID: sessionID)
            }
            context.release()

        case "UserPromptSubmit":
            apply(.working(activity: "Thinking…"), sticky: false)
            context.release()

        case "SessionEnd":
            cancelPending(sessionID: sessionID)
            store.markSessionEnded(sessionID)
            context.release()

        default:
            context.release()
        }
    }

    // MARK: - Relayed from a host

    /// A hook event a host's helper relayed, routed exactly as a local one
    /// with four differences: row ids are scoped to the host and home, the
    /// tool is looked up in the host's mirror, `cwd` is a path on the host
    /// and is kept as given, and holding needs the helper's say-so as well
    /// as this Mac's.
    ///
    /// `held` is the helper's: false means it has already answered {}, so
    /// nothing here may hold the request or reply to it. When it is true and
    /// this Mac declines to hold, `respond` gets {} before this returns, so
    /// the helper lets go at once. That matters most for Grok, which counts
    /// a hook that takes about 3 s as consent.
    func handleRemote(
        event: String, body: [String: Any], accountLabel: String?,
        origin: RemoteHookOrigin, rid: String, held: Bool,
        respond: @escaping (Data, ((Bool) -> Void)?) -> Void
    ) {
        // A follower that reconnects replays every hold still open. The
        // first copy is already answerable, and holding the second would
        // supersede the first by answering it {}.
        if held, pendingApprovals.values.contains(where: { $0.remote?.rid == rid }) { return }

        let release: () -> Void = held ? { respond(Data("{}".utf8), nil) } : {}
        let context = HookContext(
            rowID: { RemoteIdentity.sessionID(hostID: origin.hostID, home: origin.home, localID: $0) },
            // A home the mirror refuses cannot say whose session this is,
            // so it is treated as unknown rather than guessed at.
            tool: { raw in origin.mirrorHome.flatMap { Self.originTool(rawSessionID: raw, home: $0) } },
            cwd: body["cwd"] as? String,
            accountLabel: accountLabel,
            host: origin.hostName,
            mayHold: { kind, tool in
                guard held else { return false }
                switch kind {
                case .claudeHook:
                    // Both the transcript state and the process chain must
                    // say Claude. Either one alone has been wrong before.
                    return tool == .claudeCode
                        && origin.peer.contains("claude")
                        && !origin.peer.contains("grok")
                        && !origin.approvalsOff.contains(.claudeCode)
                case .openCodePlugin:
                    return !origin.approvalsOff.contains(.openCode)
                }
            },
            release: release,
            hold: { [weak self] sessionID, kind in
                guard let self else { release(); return }
                self.holdForDecision(
                    sessionID: sessionID, kind: kind, window: self.remoteDecisionHold,
                    respond: respond,
                    isGone: { false },
                    remote: (rid, origin.hostID))
            })
        dispatch(event: event, body: body, context: context)
    }

    /// The helper says a held request is over: answered from another Mac,
    /// at the terminal, or let go. Nothing is sent back for it, and the row
    /// stops asking, as it does for a local PermissionResult.
    func cancelRemote(rid: String) {
        for (sessionID, pending) in pendingApprovals where pending.remote?.rid == rid {
            dropPending(sessionID: sessionID)
            leaveApproval(sessionID: sessionID)
        }
    }

    /// The prompt was settled somewhere other than this popover, so the
    /// row stops claiming it needs approval rather than waiting a poll.
    private func leaveApproval(sessionID: UUID) {
        store.update(id: sessionID) { session in
            if case .waitingApproval = session.status {
                session.status = .working(activity: "Working…")
            }
        }
    }

    /// A host's relay stopped, or its helper process exited. Its holds are
    /// forgotten without an answer: the helper that held them is gone, so
    /// a reply could only reach a new one that has never heard of them,
    /// and replying to a stopped host would start a helper for it. The row
    /// keeps its prompt, which an agent whose hook lost its helper falls
    /// back to showing in its own terminal; a hold a surviving owner still
    /// has is replayed to the next helper and held again.
    func dropRemote(hostID: UUID) {
        for (sessionID, pending) in pendingApprovals where pending.remote?.hostID == hostID {
            dropPending(sessionID: sessionID)
        }
    }

    /// Whether a decision can still be sent for this row. A row can show an
    /// approval prompt that nothing here is holding, when the helper or
    /// this Mac declined to hold it, and only a held one can be answered
    /// from the popover.
    func isHolding(sessionID: UUID) -> Bool {
        guard let pending = pendingApprovals[sessionID] else { return false }
        return !pending.isGone()
    }

    /// Which tool a hook event came from. Grok Build's Claude-compat layer
    /// runs the same hook commands, and Kimi's own hooks post the same
    /// schema, so check both before assuming Claude Code.
    ///
    /// `home` is whose state to consult: this Mac's for the local hook
    /// server, a host's mirrored home for an event relayed from it.
    ///
    /// Nil for an id that could name a path: Grok's lookup joins the id
    /// onto a directory, and a relayed id is the remote host's to choose,
    /// so one holding a slash or a dot component could reach outside the
    /// mirror. Such an id is no tool's, and above all not Claude's, so it is
    /// never held.
    nonisolated static func originTool(
        rawSessionID: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentTool? {
        guard !rawSessionID.isEmpty, !rawSessionID.contains("/"), !rawSessionID.contains("\0"),
              rawSessionID != ".", rawSessionID != ".."
        else { return nil }
        if rawSessionID.hasPrefix("session_") {
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
        let grokRoot = home.appendingPathComponent(".grok")
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
    private func handleOpenCodePermission(_ body: [String: Any], context: HookContext) {
        guard let rawSessionID = body["sessionID"] as? String else {
            context.release()
            return
        }
        let sessionID = context.rowID(StableID.uuid(for: rawSessionID))
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
            sticky: true, cwd: body["directory"] as? String, accountLabel: nil,
            host: context.host
        )
        if mayHold(.openCodePlugin, .openCode, context) {
            context.hold(sessionID, .openCodePlugin)
        } else {
            context.release()
        }
    }

    static func commandDescription(_ body: [String: Any]) -> String {
        let toolName = body["tool_name"] as? String ?? "tool"
        let input = body["tool_input"] as? [String: Any]
        if toolName == "Bash", let command = input?["command"] as? String {
            return shorten(command)
        }
        // A question the agent wants to put to the user. The row used to
        // read "$ AskUserQuestion", which names the mechanism and says
        // nothing about what is being asked, and the question is the
        // entire content of the request. Approving lets the agent ask it;
        // the answer still happens wherever the session is.
        if let question = questionText(input) { return shorten(question) }
        if let path = input?["file_path"] as? String {
            return "\(toolName) \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        return toolName
    }

    /// The first question of an AskUserQuestion call, with a count when
    /// there are more. Read structurally rather than by tool name, so a
    /// renamed tool with the same shape still reads properly, and anything
    /// without a question falls through to the old description.
    nonisolated static func questionText(_ input: [String: Any]?) -> String? {
        guard let questions = input?["questions"] as? [[String: Any]],
              let first = questions.first,
              let question = (first["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty
        else { return nil }
        return questions.count > 1 ? "\(question) (+\(questions.count - 1) more)" : question
    }

    private nonisolated static func shorten(_ text: String, limit: Int = 80) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        return flattened.count <= limit ? flattened : String(flattened.prefix(limit)) + "…"
    }

    // MARK: - Pending decisions

    private func holdForDecision(
        sessionID: UUID, kind: ApprovalKind, window: Duration,
        respond: @escaping (Data, ((Bool) -> Void)?) -> Void,
        isGone: @escaping () -> Bool,
        remote: (rid: String, hostID: UUID)?
    ) {
        // A newer request for the same session supersedes any stale one.
        cancelPending(sessionID: sessionID)
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self else { return }
            if remote == nil {
                // Fail open: no decision, terminal prompt proceeds as normal.
                self.finishPending(sessionID: sessionID, json: Data("{}".utf8))
            } else {
                // The helper let go at 345 s and answered {} itself, so
                // there is nothing left to reply to, and the row stops
                // asking for an answer nothing can take.
                self.pendingApprovals.removeValue(forKey: sessionID)
                self.leaveApproval(sessionID: sessionID)
            }
            // Drop the sticky override too, or the row keeps showing
            // Approve/Deny buttons that can no longer answer anything.
            self.store.clearHookOverride(sessionID: sessionID)
        }
        pendingApprovals[sessionID] = PendingApproval(
            kind: kind, respond: respond, isGone: isGone, timeout: timeout, remote: remote)
    }

    private func finishPending(sessionID: UUID, json: Data) {
        guard let pending = pendingApprovals.removeValue(forKey: sessionID) else { return }
        pending.timeout.cancel()
        pending.respond(json, nil)
    }

    private func cancelPending(sessionID: UUID) {
        finishPending(sessionID: sessionID, json: Data("{}".utf8))
    }

    func resolveApproval(sessionID: UUID, allow: Bool) -> Bool {
        guard let pending = pendingApprovals[sessionID] else { return false }
        if pending.isGone() {
            dropPending(sessionID: sessionID)
            return false
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
        pending.respond(json) { [weak self] delivered in
            guard !delivered else { return }
            Task { @MainActor in
                self?.store.noteApprovalDeliveryFailed(sessionID: sessionID)
            }
        }
        store.clearHookOverride(sessionID: sessionID)
        return true
    }
}
