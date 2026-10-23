import Foundation
import os

/// How a remote row's Approve and Deny can reach its prompt, if at all.
enum RemoteAnswerability: Equatable {
    /// A relayed hook request is held here, so the decision goes back as
    /// its reply. Claude Code and OpenCode only.
    case held
    /// The session sits in a tmux pane the helper can type into.
    case keystrokes
    /// Nothing on this Mac can answer it. The row says so instead of
    /// offering buttons that would do nothing.
    case terminalOnly
}

/// Answers remote sessions. The store calls it for any row with a host, in
/// place of every route that reaches into a terminal on this Mac.
@MainActor
protocol RemoteActing: AnyObject {
    func answerability(for session: AgentSession) -> RemoteAnswerability
    func answer(_ session: AgentSession, allow: Bool)
    func reply(
        _ session: AgentSession, text: String,
        completion: @escaping @MainActor (SessionStore.ReplyResult) -> Void)
}

/// One command to a host's helper. The channel in the app, a recorder in
/// tests, so the keystroke path can be checked without ssh or tmux.
protocol RemoteRequesting: Sendable {
    func request(
        _ command: String, _ arguments: [String: JSONValue], timeout: Duration
    ) async throws -> Data
}

extension SSHChannel: RemoteRequesting {}

private let remoteAnswerLog = Logger(subsystem: "app.swarmbar.SwarmBar", category: "remote")

extension RemoteMonitorSupervisor: RemoteActing {
    func answerability(for session: AgentSession) -> RemoteAnswerability {
        switch session.tool {
        case .claudeCode, .openCode:
            // Only a held request can take a decision, and a hold can end
            // at any moment (answered elsewhere, timed out, its helper
            // gone), so this is asked afresh every time.
            return hookServer?.isHolding(sessionID: session.id) == true ? .held : .terminalOnly
        case .codex, .kimiCode, .bearCode, .grokBuild, .antigravity:
            return keystrokeTarget(for: session) == nil ? .terminalOnly : .keystrokes
        }
    }

    func answer(_ session: AgentSession, allow: Bool) {
        Task { await performAnswer(session, allow: allow) }
    }

    /// Reply over tmux is not built yet, and the row does not offer it.
    func reply(
        _ session: AgentSession, text: String,
        completion: @escaping @MainActor (SessionStore.ReplyResult) -> Void
    ) {
        completion(.failed("Replies cannot reach \(session.host ?? "that host") yet."))
    }

    /// `answer`, awaitable, and saying whether keys were sent. Whenever it
    /// sends nothing the row is left exactly as it was, still asking, so
    /// the user answers at the terminal rather than trusting a row that
    /// moved on for keys that never landed.
    @discardableResult
    func performAnswer(_ session: AgentSession, allow: Bool) async -> Bool {
        let host = session.host ?? "?"
        // Claude Code and OpenCode are never typed at, pane or not: their
        // only answer is the held one, which the store has already tried.
        guard answerability(for: session) == .keystrokes,
              let target = keystrokeTarget(for: session)
        else {
            remoteAnswerLog.notice("answer: \(session.tool.rawValue, privacy: .public) on \(host, privacy: .public) has no keystroke channel, nothing sent")
            return false
        }
        // A second click while the first is in flight would read the same
        // screen and could press into whatever the first answer left behind.
        guard answering.insert(session.id).inserted else {
            remoteAnswerLog.notice("answer: already answering on \(host, privacy: .public), nothing sent")
            return false
        }
        defer { answering.remove(session.id) }

        let toggles = keystrokeToggles()
        let route = ApprovalRouter.route(
            tool: session.tool, allow: allow,
            in: .init(
                grokKeystrokes: toggles.grok, antigravityKeystrokes: toggles.antigravity,
                // A remote row is never a mock, whatever its path.
                hasProjectPath: true))
        let requester = requester(target.connection)
        let pane: JSONValue = .object([
            "socket": .string(target.pane.socket), "id": .string(target.pane.id),
        ])

        var screen: String?
        if RemoteAnswerPlan.needsScreen(route) {
            do {
                screen = RemoteAnswerPlan.screen(
                    fromCapture: try await requester.request("capture", ["pane": pane], timeout: .seconds(30)))
            } catch {
                remoteAnswerLog.notice("answer: capture on \(host, privacy: .public) failed, nothing sent: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        let choose = allow ? TuiPromptLayout.approveOnceOption(in:) : TuiPromptLayout.rejectOption(in:)
        guard let command = RemoteAnswerPlan.command(route: route, screen: screen, choose: choose) else {
            remoteAnswerLog.notice("answer: no readable prompt for \(session.tool.rawValue, privacy: .public) on \(host, privacy: .public), nothing sent")
            return false
        }

        let reply: Data
        do {
            reply = try await requester.request("keys", [
                "pane": pane,
                "keys": .array(command.keys.map(JSONValue.string)),
                "expect": .array(command.expect.map(JSONValue.string)),
            ], timeout: .seconds(30))
        } catch {
            remoteAnswerLog.notice("answer: keys on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
        switch RemoteAnswerPlan.keysOutcome(from: reply) {
        case .sent:
            store.noteRemoteAnswerSent(session, allow: allow)
            return true
        case .notSent(let reason):
            remoteAnswerLog.notice("answer: keys on \(host, privacy: .public) not sent: \(reason, privacy: .public)")
            return false
        }
    }

    /// The pane a session's keys go to and the connection that reaches it,
    /// or nil when keystrokes may not or cannot answer it.
    ///
    /// The pane is the one its own process runs in, matched by pid in the
    /// snapshot last applied in full. Two agents can share a pane (a codex
    /// started inside a claude), which is fine: the keys are chosen and
    /// confirmed against what that pane shows.
    private func keystrokeTarget(
        for session: AgentSession
    ) -> (pane: RemotePane, connection: RemoteHostConnection)? {
        guard let hostName = session.host, let pid = session.pid,
              let connection = connection(forHostName: hostName),
              let pane = connection.lastSnapshot?.processes
                .first(where: { $0.pid == Int(pid) })?.pane
        else { return nil }
        // Read from the registry, not the connection's copy, so switching
        // approvals off in Settings applies at once without a restart.
        let off = registry.host(id: connection.host.id)?.approvalsOff ?? connection.host.approvalsOff
        guard !off.contains(session.tool) else { return nil }
        let toggles = keystrokeToggles()
        switch session.tool {
        case .grokBuild where !toggles.grok: return nil
        case .antigravity where !toggles.antigravity: return nil
        default: return (pane, connection)
        }
    }
}
