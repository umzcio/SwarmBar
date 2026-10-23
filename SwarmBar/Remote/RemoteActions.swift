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
    /// Whether a written reply can reach this session. Separate from
    /// `answerability` because a reply is always typed: a held Claude row
    /// is answerable with no pane at all, but cannot be replied to.
    func canReply(_ session: AgentSession) -> Bool
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

    func canReply(_ session: AgentSession) -> Bool {
        paneTarget(for: session) != nil
    }

    func reply(
        _ session: AgentSession, text: String,
        completion: @escaping @MainActor (SessionStore.ReplyResult) -> Void
    ) {
        Task { completion(await performReply(session, text: text)) }
    }

    /// `reply`, awaitable. The remote form of TerminalFocuser.sendReply:
    /// paste, read the screen back, and press Enter only where the paste
    /// is visible. A reply left unsent in the composer is recoverable, one
    /// submitted half-delivered is not, so `.sent` means only that the
    /// helper confirmed it pressed Enter.
    ///
    /// The approval switches do not gate this. A reply is not an answer,
    /// and the local reply goes through whatever the keystroke switches
    /// say, so the remote one does too.
    func performReply(_ session: AgentSession, text: String) async -> SessionStore.ReplyResult {
        let host = session.host ?? "?"
        guard let target = paneTarget(for: session) else {
            remoteAnswerLog.notice("reply: \(session.tool.rawValue, privacy: .public) on \(host, privacy: .public) has no pane, nothing sent")
            return .failed("This session isn't in tmux on \(host), so reply in its terminal.")
        }
        // The helper strips these anyway. Stripping first means the probe
        // looked for on screen is cut from what actually lands.
        let pasted = RemoteAnswerPlan.pasteText(text)
        guard let probe = TerminalFocuser.verificationProbe(for: pasted) else {
            return .failed("Nothing to send.")
        }
        // The answer's guard, shared: a second Send would paste the text
        // twice, and a reply and an answer must not type into one pane at
        // once.
        guard answering.insert(session.id).inserted else {
            remoteAnswerLog.notice("reply: already sending on \(host, privacy: .public), nothing sent")
            return .failed("A reply is already on its way to this session.")
        }
        defer { answering.remove(session.id) }

        let requester = requester(target.connection)
        let pane: JSONValue = .object([
            "socket": .string(target.pane.socket), "id": .string(target.pane.id),
        ])
        // pid and comm make the helper re-read its process table before
        // pasting and before pressing, and refuse if that pid is gone, is
        // another agent, or has left this pane.
        let process: [String: JSONValue] = [
            "pid": .int(target.process.pid), "comm": .string(target.process.comm),
        ]

        do {
            let reply = try await requester.request(
                "paste", process.merging(["pane": pane, "text": .string(pasted)]) { $1 },
                timeout: .seconds(30))
            if case .notSent(let reason) = RemoteAnswerPlan.keysOutcome(from: reply) {
                remoteAnswerLog.notice("reply: paste on \(host, privacy: .public) not sent: \(reason, privacy: .public)")
                return .failed("Could not paste into this session on \(host), so nothing was sent.")
            }
        } catch {
            remoteAnswerLog.notice("reply: paste on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            // A request that timed out may still have pasted, so this
            // claims nothing about the composer.
            return .failed("Could not reach \(host), so the reply was not submitted. Check the terminal.")
        }

        // From here the text may be sitting in the composer, so every
        // failure says to look at the terminal.
        let screen: String?
        do {
            screen = RemoteAnswerPlan.screen(fromCapture: try await requester.request(
                "capture", ["pane": pane], timeout: .seconds(30)))
        } catch {
            screen = nil
        }
        guard let screen else {
            remoteAnswerLog.notice("reply: capture on \(host, privacy: .public) failed, Enter not sent")
            return .failed("Could not read the screen on \(host), so nothing was submitted. Check the terminal.")
        }
        guard screen.contains(probe) else {
            return .failed(
                "The text did not appear in the composer, so nothing was submitted. Check the terminal.")
        }
        // Two round trips have passed. A host that went dark or a helper
        // that restarted meanwhile leaves a pane map from before the gap.
        guard let current = paneTarget(for: session),
              current.pane == target.pane, current.process.pid == target.process.pid
        else {
            remoteAnswerLog.notice("reply: \(host, privacy: .public) changed while pasting, Enter not sent")
            return .failed("The session on \(host) changed while pasting, so nothing was submitted. Check the terminal.")
        }

        do {
            // The probe goes along so the helper re-confirms the paste is
            // still on screen at the moment it presses Enter.
            let reply = try await requester.request(
                "keys", process.merging([
                    "pane": pane, "keys": .array([.string("\n")]), "expect": .array([.string(probe)]),
                ]) { $1 },
                timeout: .seconds(30))
            switch RemoteAnswerPlan.keysOutcome(from: reply) {
            case .sent:
                store.noteReplySent(session.id)
                return .sent
            case .notSent(let reason):
                remoteAnswerLog.notice("reply: Enter on \(host, privacy: .public) not sent: \(reason, privacy: .public)")
                return .failed("The reply was pasted on \(host) but not submitted. Check the terminal.")
            }
        } catch {
            // A request that timed out may still have pressed Enter, so this
            // claims neither outcome.
            remoteAnswerLog.notice("reply: Enter on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed("Could not confirm the reply was submitted on \(host). Check the terminal.")
        }
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
        if RemoteAnswerPlan.needsScreen(tool: session.tool, route: route) {
            do {
                screen = RemoteAnswerPlan.screen(
                    fromCapture: try await requester.request("capture", ["pane": pane], timeout: .seconds(30)))
            } catch {
                remoteAnswerLog.notice("answer: capture on \(host, privacy: .public) failed, nothing sent: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        let choose = allow ? TuiPromptLayout.approveOnceOption(in:) : TuiPromptLayout.rejectOption(in:)
        guard let command = RemoteAnswerPlan.command(
            tool: session.tool, route: route, screen: screen, choose: choose)
        else {
            remoteAnswerLog.notice("answer: no readable prompt for \(session.tool.rawValue, privacy: .public) on \(host, privacy: .public), nothing sent")
            return false
        }
        // The capture was a round trip, and the host may have gone dark or
        // its helper restarted meanwhile. Sending now would start ssh again
        // and aim by a pane map from before the gap.
        guard let current = keystrokeTarget(for: session),
              current.pane == target.pane, current.process.pid == target.process.pid
        else {
            remoteAnswerLog.notice("answer: \(host, privacy: .public) changed while reading the prompt, nothing sent")
            return false
        }

        let reply: Data
        do {
            // pid and comm let the helper re-read its process table at press
            // time and refuse if that pid is gone, is another agent, or no
            // longer sits in this pane.
            reply = try await requester.request("keys", [
                "pane": pane,
                "keys": .array(command.keys.map(JSONValue.string)),
                "expect": .array(command.expect.map(JSONValue.string)),
                "pid": .int(target.process.pid),
                "comm": .string(target.process.comm),
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

    private typealias PaneTarget = (
        process: RemoteProcessRecord, pane: RemotePane, connection: RemoteHostConnection)

    /// The process and pane a session's keys or reply go to and the
    /// connection that reaches them, or nil when nothing can be typed there.
    ///
    /// The pane is the one its own process runs in, matched by pid in the
    /// snapshot last applied in full. Two agents can share a pane (a codex
    /// started inside a claude), which is fine: the keys are chosen and
    /// confirmed against what that pane shows.
    ///
    /// Only while the host is reachable, its helper is known to be the
    /// bundled one (an old helper ignores the press-time pid and comm
    /// check), and a snapshot has landed since the last gap. All are
    /// checked before any request, so a click on a dark host's row never
    /// starts ssh, and a pane map from before a gap never aims a key.
    private func paneTarget(for session: AgentSession) -> PaneTarget? {
        guard let hostName = session.host, let pid = session.pid,
              store.remoteReachability[hostName] == .reachable,
              let connection = connection(forHostName: hostName),
              connection.helperIsCurrent,
              let process = connection.lastSnapshot?.processes.first(where: { $0.pid == Int(pid) }),
              let pane = process.pane
        else { return nil }
        return (process, pane, connection)
    }

    /// `paneTarget`, for an approval: also nil when approvals are off for
    /// this tool on this host, or its keystroke switch is off.
    private func keystrokeTarget(for session: AgentSession) -> PaneTarget? {
        guard let target = paneTarget(for: session) else { return nil }
        let connection = target.connection
        // Read from the registry, not the connection's copy, so switching
        // approvals off in Settings applies at once without a restart.
        let off = registry.host(id: connection.host.id)?.approvalsOff ?? connection.host.approvalsOff
        guard !off.contains(session.tool) else { return nil }
        let toggles = keystrokeToggles()
        switch session.tool {
        case .grokBuild where !toggles.grok: return nil
        case .antigravity where !toggles.antigravity: return nil
        default: return target
        }
    }
}
