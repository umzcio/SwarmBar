import AppKit
import Foundation
import Observation

/// Single source of truth. Monitors push updates in; views observe.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []
    var isPaused = false

    /// Live state of the hook bridge, surfaced in Settings. Set by HookServer.
    var hookServerState: HookServer.ServerState = .starting

    // Drives the menu bar glyph's animation frame. The MenuBarExtra label
    // only reliably re-renders on observable data changes, so the ticker
    // lives here rather than in the label view. Fill cycle steps at 450ms
    // per the icon spec; the attention flash alternates at 1Hz. The phase
    // only advances (and so the label only re-renders) while animating.
    private(set) var iconPhase = 0
    @ObservationIgnored private var iconTicker: Task<Void, Never>?

    init() {
        // No ticker until something needs to animate; see refreshIconTicker.
    }

    /// Starts the animation ticker when the glyph has a frame to advance and
    /// tears it down when it does not, so a resting menu bar app is not
    /// waking the main actor twice a second forever.
    private func refreshIconTicker() {
        if iconNeedsAnimation {
            guard iconTicker == nil else { return }
            iconTicker = Task { [weak self] in
                while !Task.isCancelled {
                    let flashing = (self?.approvalCount ?? 0) > 0
                    try? await Task.sleep(for: .milliseconds(flashing ? 500 : 450))
                    guard let self, !Task.isCancelled else { return }
                    guard self.iconNeedsAnimation else {
                        // Clearing the handle here is load bearing. Without it
                        // the property keeps pointing at a finished Task, and
                        // the next refreshIconTicker sees a non-nil handle,
                        // skips starting a ticker, and the icon freezes for
                        // the life of the process.
                        self.iconTicker = nil
                        return
                    }
                    self.iconPhase &+= 1
                }
            }
        } else {
            iconTicker?.cancel()
            iconTicker = nil
            // Leave iconPhase where it is; the label renders solid() when
            // nothing is animating, so the stale phase is never shown.
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

    /// Whether the menu bar glyph has a frame to advance. Mirrors what
    /// MenuBarLabel actually renders: the attention flash for pending
    /// approvals, the fill cycle while agents work and the app is not
    /// paused, and nothing otherwise.
    var iconNeedsAnimation: Bool {
        if approvalCount > 0 { return true }
        return anyActive && !isPaused
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
        refreshIconTicker()
    }

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
        refreshIconTicker()
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
        for id in incomingIds {
            guard let endedAt = endedSessions[id] else { continue }
            if let session = sessions.first(where: { $0.id == id }),
               session.lastActivityAt > endedAt {
                // Genuinely new activity after the exit: the session was
                // resumed and owns its status again.
                endedSessions.removeValue(forKey: id)
            } else {
                update(id: id) { $0.status = .idle }
            }
        }
        for (id, ackTime) in acknowledgedAt {
            guard let session = sessions.first(where: { $0.id == id }) else { continue }
            if session.lastActivityAt > ackTime {
                // The dismissal is over: genuinely new activity. Re-arm the
                // alert so the next question is announced.
                acknowledgedAt.removeValue(forKey: id)
                alertedStatus.removeValue(forKey: id)
            } else if case .waitingInput(let prompt) = session.status {
                update(id: id) { $0.status = .done(summary: prompt) }
            }
        }
        pruneSessionRecords()
        reapplyHookOverrides()
        pruneAlertRecords()
        noteAttentionTransitions()
        refreshIconTicker()
    }

    /// Forgets bookkeeping for sessions the store no longer holds, so a
    /// long-running app does not accumulate entries for sessions that aged
    /// out of discovery.
    private func pruneSessionRecords() {
        let known = Set(sessions.map(\.id))
        endedSessions = endedSessions.filter { known.contains($0.key) }
        acknowledgedAt = acknowledgedAt.filter { known.contains($0.key) }
    }

    /// Drops alert records for sessions that are settled: no longer needing
    /// attention after this cycle's overrides are applied, or gone entirely.
    /// Doing this once per sync (rather than inside every mutation) is what
    /// keeps a mid-sync status flicker from re-arming the alert.
    ///
    /// Dismissed sessions keep their record even though `acknowledgedAt`
    /// forces them to done. The poller re-derives the waiting verdict from
    /// the unchanged transcript every cycle, so pruning them here would let
    /// the next poll read as a fresh transition and alert again.
    private func pruneAlertRecords() {
        let stillWaiting = Set(
            sessions.filter { $0.status.needsAttention }.map(\.id)
        )
        alertedStatus = alertedStatus.filter {
            stillWaiting.contains($0.key) || acknowledgedAt[$0.key] != nil
        }
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
    /// SessionEnd hook fires on /exit), and when. The transcript keeps
    /// looking fresh for a while, so without this an exited session reads
    /// as waiting until the stale window catches up. Keeping the timestamp
    /// (rather than just the id) is what lets a resumed session recover:
    /// claude --resume reuses the id and appends to the same transcript.
    @ObservationIgnored private var endedSessions: [UUID: Date] = [:]

    func markSessionEnded(_ sessionID: UUID) {
        endedSessions[sessionID] = .now
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
        refreshIconTicker()
    }

    // MARK: - Attention notifications

    /// Called once per session per entry into a needs-attention status;
    /// the app wires this to AgentNotifier, tests to a collector.
    @ObservationIgnored var attentionAlertHandler: ((AgentSession) -> Void)?

    /// The attention status each session was last alerted for. Keyed by
    /// session so a status that flickers mid-sync (the poller overwrites a
    /// held approval before reapplyHookOverrides restores it) cannot look
    /// like a fresh transition on the next pass.
    @ObservationIgnored private var alertedStatus: [UUID: String] = [:]

    private func noteAttentionTransitions() {
        for session in sessions where session.status.needsAttention {
            let label = session.status.label
            guard alertedStatus[session.id] != label else { continue }
            alertedStatus[session.id] = label
            attentionAlertHandler?(session)
        }
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
    // directly. Real sessions are answered through their tool's own control
    // channel: a held hook decision where one is pending, otherwise tty
    // keystrokes for the TUI tools, falling back to focusing the terminal
    // when nothing can be answered remotely. Session state is never written.
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
            answerTuiPrompt(session, keys: TuiAnswer.grokApprove)
            return
        }
        if session.tool == .codex {
            // Codex's approval modal has labeled hotkeys: y approves once,
            // esc rejects (ExecApproval decision Abort). Semantic keys, not
            // positional, so no arrow navigation needed. The rollout records
            // the outcome as the call's output line.
            answerTuiPrompt(session, keys: TuiAnswer.codexApprove)
            return
        }
        if session.tool == .kimiCode || session.tool == .bearCode {
            // The Kimi-family selector wraps, so navigation counts are
            // unsafe; the option is read off the screen and answered by
            // its own number. PermissionResult (hook) clears the row.
            answerNumberedPrompt(session, choose: TuiPromptLayout.approveOnceOption(in:))
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
            answerTuiPrompt(session, keys: TuiAnswer.grokDeny)
            return
        }
        if session.tool == .codex {
            answerTuiPrompt(session, keys: TuiAnswer.codexDeny)
            return
        }
        if session.tool == .kimiCode || session.tool == .bearCode {
            answerNumberedPrompt(session, choose: TuiPromptLayout.rejectOption(in:))
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
        choose: @escaping @Sendable (String) -> TuiPromptLayout.Option?
    ) {
        let id = session.id
        let path = session.projectPath
        Task.detached {
            guard let screen = TerminalFocuser.screenText(sessionID: id, projectPath: path),
                  let option = choose(screen)
            else {
                TerminalFocuser.focus(sessionID: id, projectPath: path)
                return
            }
            let outcome = TerminalFocuser.answerNumbered(
                sessionID: id, projectPath: path,
                number: option.number, expectedLabel: option.label)
            if outcome != .sent {
                // The prompt moved or the terminal is gone. Never press a
                // digit into an unverified selector; bring the user to it.
                TerminalFocuser.focus(sessionID: id, projectPath: path)
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
        refreshIconTicker()
    }
}

@MainActor
protocol ApprovalResponding: AnyObject {
    /// Returns true if a pending hook decision existed and was resolved.
    func resolveApproval(sessionID: UUID, allow: Bool) -> Bool
}
