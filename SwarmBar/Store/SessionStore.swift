import AppKit
import Foundation
import Observation

/// Single source of truth. Monitors push updates in; views observe.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []
    var isPaused = false

    // Drives the menu bar glyph's animation frame. The MenuBarExtra label
    // only reliably re-renders on observable data changes, so the ticker
    // lives here rather than in the label view. Fill cycle steps at 450ms
    // per the icon spec; the attention flash alternates at 1Hz. The phase
    // only advances (and so the label only re-renders) while animating.
    private(set) var iconPhase = 0
    @ObservationIgnored private var iconTicker: Task<Void, Never>?

    init() {
        iconTicker = Task { [weak self] in
            while !Task.isCancelled {
                let flashing = (self?.approvalCount ?? 0) > 0
                try? await Task.sleep(for: .milliseconds(flashing ? 500 : 450))
                guard let self else { return }
                if self.approvalCount > 0 || (self.anyActive && !self.isPaused) {
                    self.iconPhase &+= 1
                }
            }
        }
    }

    // Derived slices the popover renders. Active includes live sessions
    // that just finished a turn: their process is still up and their
    // terminal is a click away, so they are not history yet.
    var attention: [AgentSession] { sessions.filter { $0.status.needsAttention } }
    var active: [AgentSession] {
        sessions.filter { session in
            if session.status.isActive { return true }
            if case .done = session.status { return session.processAlive }
            return false
        }
    }

    /// Tools that mint a session per launch (Grok, OpenCode) leave trails
    /// of identical finished rows; Recent keeps only the newest per
    /// project for those. Claude and Codex sessions are distinct
    /// conversations and all stay visible.
    private static let launchScopedTools: Set<AgentTool> = [.grokBuild, .openCode, .kimiCode, .bearCode]

    /// How long a finished session stays in Recent. Discovery keeps a
    /// longer window so quiet-but-open sessions are still found, but a
    /// session that ended hours ago is history, not status.
    static let recentRetention: TimeInterval = 60 * 60

    var recent: [AgentSession] {
        let activeIds = Set(active.map(\.id))
        let finished = sessions.filter {
            !$0.status.needsAttention && !activeIds.contains($0.id)
                && Date.now.timeIntervalSince($0.lastActivityAt) < Self.recentRetention
        }
        var newestByProject: [String: Date] = [:]
        for session in finished where Self.launchScopedTools.contains(session.tool) {
            let key = "\(session.tool.rawValue)|\(session.projectPath?.path ?? session.projectName)"
            newestByProject[key] = max(newestByProject[key] ?? .distantPast, session.lastActivityAt)
        }
        return finished.filter { session in
            guard Self.launchScopedTools.contains(session.tool) else { return true }
            let key = "\(session.tool.rawValue)|\(session.projectPath?.path ?? session.projectName)"
            return session.lastActivityAt >= newestByProject[key] ?? .distantPast
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// What the popover actually lists; the header counts this, not the
    /// full discovery set.
    var visibleCount: Int { attention.count + active.count + recent.count }

    var anyActive: Bool { !active.isEmpty }
    var attentionCount: Int { attention.count }

    /// Pending approvals only. The icon's flash is reserved for these;
    /// waiting-on-you sessions surface through the count text so the fill
    /// cycle stays visible while agents work.
    var approvalCount: Int {
        sessions.filter {
            if case .waitingApproval = $0.status { return true }
            return false
        }.count
    }

    // Called by monitors.
    func upsert(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            var merged = session
            merged.startedAt = sessions[index].startedAt
            merged.accountLabel = session.accountLabel ?? sessions[index].accountLabel
            sessions[index] = merged
        } else {
            sessions.insert(session, at: 0)
        }
        noteAttentionTransitions()
    }

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    /// Replaces one tool's sessions with a freshly discovered set: upserts
    /// each and drops that tool's sessions that no longer exist. Hook
    /// overrides win over transcript-derived status: sticky ones (pending
    /// approvals) until resolved, others for a grace window that covers
    /// polling lag.
    func sync(tool: AgentTool, sessions incoming: [AgentSession]) {
        let incomingIds = Set(incoming.map(\.id))
        for session in incoming { upsert(session) }
        sessions.removeAll {
            $0.tool == tool && !incomingIds.contains($0.id) && hookOverrides[$0.id] == nil
        }
        for id in incomingIds where endedSessions.contains(id) {
            update(id: id) { $0.status = .idle }
        }
        for (id, ackTime) in acknowledgedAt {
            guard let session = sessions.first(where: { $0.id == id }) else { continue }
            if session.lastActivityAt > ackTime {
                acknowledgedAt.removeValue(forKey: id)
            } else if case .waitingInput(let prompt) = session.status {
                update(id: id) { $0.status = .done(summary: prompt) }
            }
        }
        reapplyHookOverrides()
        noteAttentionTransitions()
    }

    // MARK: - Hook events

    static let hookGrace: TimeInterval = 15

    struct HookOverride {
        var status: SessionStatus
        var at: Date
        var sticky: Bool
    }

    @ObservationIgnored private(set) var hookOverrides: [UUID: HookOverride] = [:]
    @ObservationIgnored weak var approvalResponder: ApprovalResponding?

    /// Sessions whose tool reported the session over (Claude and Grok's
    /// SessionEnd hook fires on /exit). The transcript keeps looking
    /// fresh for a while, so without this an exited session reads as
    /// waiting until the stale window catches up.
    @ObservationIgnored private var endedSessions: Set<UUID> = []

    func markSessionEnded(_ sessionID: UUID) {
        endedSessions.insert(sessionID)
        clearHookOverride(sessionID: sessionID)
        update(id: sessionID) { $0.status = .idle }
    }

    /// A waiting row the user dismissed reads as done until the session
    /// produces new activity; the poller would otherwise re-derive the
    /// waiting verdict from the unchanged transcript on the next sync.
    @ObservationIgnored private var acknowledgedAt: [UUID: Date] = [:]

    func acknowledge(_ session: AgentSession) {
        guard case .waitingInput(let prompt) = session.status else { return }
        acknowledgedAt[session.id] = session.lastActivityAt
        clearHookOverride(sessionID: session.id)
        update(id: session.id) { $0.status = .done(summary: prompt) }
    }

    func applyHookEvent(
        sessionID: UUID,
        tool: AgentTool,
        status: SessionStatus,
        sticky: Bool,
        cwd: String?,
        accountLabel: String?
    ) {
        hookOverrides[sessionID] = HookOverride(status: status, at: .now, sticky: sticky)
        if sessions.contains(where: { $0.id == sessionID }) {
            update(id: sessionID) { session in
                session.status = status
                session.lastActivityAt = .now
                if let accountLabel { session.accountLabel = accountLabel }
            }
        } else {
            // Hook fired before the poller discovered the transcript.
            let path = cwd.map { URL(fileURLWithPath: $0) }
            upsert(AgentSession(
                id: sessionID,
                tool: tool,
                projectName: path?.lastPathComponent ?? "session",
                projectPath: path,
                status: status,
                accountLabel: accountLabel
            ))
        }
    }

    func clearHookOverride(sessionID: UUID) {
        hookOverrides.removeValue(forKey: sessionID)
    }

    private func reapplyHookOverrides() {
        for (id, override) in hookOverrides {
            if !override.sticky, Date.now.timeIntervalSince(override.at) > Self.hookGrace {
                hookOverrides.removeValue(forKey: id)
                continue
            }
            update(id: id) { $0.status = override.status }
        }
    }

    func update(id: UUID, _ mutate: (inout AgentSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
        noteAttentionTransitions()
    }

    // MARK: - Attention notifications

    /// Called once per session per entry into a needs-attention status;
    /// the app wires this to AgentNotifier, tests to a collector.
    @ObservationIgnored var attentionAlertHandler: ((AgentSession) -> Void)?
    @ObservationIgnored private var alertedKeys: Set<String> = []

    private func noteAttentionTransitions() {
        var current: Set<String> = []
        for session in sessions where session.status.needsAttention {
            let key = "\(session.id)|\(session.status.label)"
            current.insert(key)
            if !alertedKeys.contains(key) {
                alertedKeys.insert(key)
                attentionAlertHandler?(session)
            }
        }
        alertedKeys.formIntersection(current)
    }

    /// The held hook connection broke before the decision reached the agent.
    /// The row said "Running"; say plainly that it did not land, so the user
    /// goes to the terminal instead of trusting a false confirmation.
    func noteApprovalDeliveryFailed(sessionID: UUID) {
        update(id: sessionID) { session in
            session.status = .waitingInput(prompt: "Answer at the terminal, SwarmBar could not deliver")
        }
    }

    // Called by row buttons. Mock sessions (no projectPath) transition state
    // directly. Real sessions are read-only per CLAUDE.md: the buttons bring
    // you to the session's terminal instead of writing to the tool's files;
    // proper control channels are a later design.
    func approve(_ session: AgentSession) {
        guard case .waitingApproval(let command) = session.status else { return }
        if approvalResponder?.resolveApproval(sessionID: session.id, allow: true) == true {
            let executable = command.split(separator: " ").first.map(String.init) ?? command
            update(id: session.id) { $0.status = .runningTool(activity: "Running \(executable)") }
            return
        }
        if session.tool == .grokBuild {
            // Grok's hook runner ignores deny responses (verified), so the
            // prompt is answered through its TUI selector. Layouts vary
            // (3-option shell prompts, 4-option edit prompts), but reject
            // is always last and plain approve-once second-from-last, so
            // navigate: clamp to the bottom, step up once, submit.
            guard Self.grokKeystrokesEnabled else { openInTerminal(session); return }
            answerTuiPrompt(session, keys: Array(repeating: "DOWN", count: 8) + ["UP", "\n"])
            return
        }
        if session.tool == .codex {
            // Codex's approval modal has labeled hotkeys: y approves once,
            // esc rejects (ExecApproval decision Abort). Semantic keys, not
            // positional, so no arrow navigation needed. The rollout records
            // the outcome as the call's output line.
            answerTuiPrompt(session, keys: ["y"])
            return
        }
        if session.tool == .kimiCode || session.tool == .bearCode {
            // The Kimi-family selector wraps, so navigation counts are
            // unsafe; the option is read off the screen and answered by
            // its own number. PermissionResult (hook) clears the row.
            answerNumberedPrompt(session, choose: TuiPromptLayout.approveOnce(in:))
            return
        }
        if session.projectPath != nil { openInTerminal(session); return }
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        update(id: session.id) { $0.status = .runningTool(activity: "Running \(executable)") }
    }

    func deny(_ session: AgentSession) {
        guard case .waitingApproval = session.status else { return }
        if approvalResponder?.resolveApproval(sessionID: session.id, allow: false) == true {
            update(id: session.id) { $0.status = .working(activity: "Rethinking after deny…") }
            return
        }
        if session.tool == .grokBuild {
            // Reject is the last option in every observed layout: clamp to
            // the bottom and submit; the second newline submits the reject
            // feedback field empty.
            guard Self.grokKeystrokesEnabled else { openInTerminal(session); return }
            answerTuiPrompt(session, keys: Array(repeating: "DOWN", count: 8) + ["\n", "\n"])
            return
        }
        if session.tool == .codex {
            answerTuiPrompt(session, keys: ["ESC"])
            return
        }
        if session.tool == .kimiCode || session.tool == .bearCode {
            answerNumberedPrompt(session, choose: TuiPromptLayout.reject(in:))
            return
        }
        if session.projectPath != nil { openInTerminal(session); return }
        update(id: session.id) { $0.status = .working(activity: "Rethinking approach without that command…") }
    }

    /// Reads the session's terminal, picks the option matching the intent,
    /// and presses that number. Falls back to focusing the terminal when
    /// the screen can't be read or no matching option is on it, so a
    /// misread never sends a keystroke to an unknown selector.
    /// The settings toggle for Grok's remote answers; off means Approve
    /// and Deny just focus the terminal.
    static var grokKeystrokesEnabled: Bool {
        (UserDefaults.standard.object(forKey: "grokKeystrokeAnswers") as? Bool) ?? true
    }

    private func answerNumberedPrompt(
        _ session: AgentSession,
        choose: @escaping @Sendable (String) -> Int?
    ) {
        let id = session.id
        let path = session.projectPath
        Task.detached {
            guard let screen = TerminalFocuser.screenText(sessionID: id, projectPath: path),
                  let number = choose(screen),
                  TerminalFocuser.sendKeys(
                    sessionID: id, projectPath: path, keys: ["\(number)"])
            else {
                TerminalFocuser.focus(sessionID: id, projectPath: path)
                return
            }
        }
    }

    private func answerTuiPrompt(_ session: AgentSession, keys: [String]) {
        let id = session.id
        let path = session.projectPath
        Task.detached {
            if !TerminalFocuser.sendKeys(sessionID: id, projectPath: path, keys: keys) {
                TerminalFocuser.focus(sessionID: id, projectPath: path)
            }
        }
    }

    func openForReply(_ session: AgentSession) {
        guard case .waitingInput = session.status else { return }
        if session.projectPath != nil { openInTerminal(session); return }
        update(id: session.id) { $0.status = .working(activity: "Continuing with your answer…") }
    }

    func openInTerminal(_ session: AgentSession) {
        let id = session.id
        let path = session.projectPath
        Task.detached {
            TerminalFocuser.focus(sessionID: id, projectPath: path)
        }
    }

    func copyProjectPath(_ session: AgentSession) {
        guard let path = session.projectPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path.path, forType: .string)
    }

    func pauseAll() {
        isPaused.toggle()
    }
}

@MainActor
protocol ApprovalResponding: AnyObject {
    /// Returns true if a pending hook decision existed and was resolved.
    func resolveApproval(sessionID: UUID, allow: Bool) -> Bool
}
