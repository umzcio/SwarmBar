import AppKit
import Foundation
import Observation

/// Single source of truth. Monitors push updates in; views observe.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []

    /// Per-host reachability, keyed by display name. A host going away is a
    /// routinely exercised path rather than an error case, so rows keep
    /// their last known status and say the host cannot be reached.
    private(set) var remoteReachability: [String: RemoteReachability] = [:]
    /// When each host's current outage began, for "Unreachable for 4 min".
    /// One outage can change its reason between polls (a timeout, then a
    /// refused connection), so only reaching the host again ends it.
    private(set) var remoteUnreachableSince: [String: Date] = [:]
    /// Called with a host's display name when it becomes reachable, so a
    /// check that could not connect earlier is not left contradicting a
    /// live connection. Set by the remote monitor supervisor.
    @ObservationIgnored var remoteReachableHandler: ((String) -> Void)?

    func noteRemoteReachability(host: String, _ state: RemoteReachability, now: Date = .now) {
        if case .unreachable = state {
            if remoteUnreachableSince[host] == nil { remoteUnreachableSince[host] = now }
        } else if remoteUnreachableSince[host] != nil {
            remoteUnreachableSince.removeValue(forKey: host)
        }
        guard remoteReachability[host] != state else { return }
        remoteReachability[host] = state
        if state == .reachable { remoteReachableHandler?(host) }
    }

    /// Forgets everything about one remote host: its rows, its reachability
    /// and the per-session records keyed by those rows. Used when a host is
    /// removed or renamed, since its monitor will never sync again to delete
    /// the rows itself and a stale row would read as a live session.
    func clearHost(_ host: String) {
        let ids = Set(sessions.filter { $0.host == host }.map(\.id))
        sessions.removeAll { $0.host == host }
        remoteReachability.removeValue(forKey: host)
        remoteUnreachableSince.removeValue(forKey: host)
        for id in ids {
            hookOverrides.removeValue(forKey: id)
            acknowledgedAt.removeValue(forKey: id)
            alertedStatus.removeValue(forKey: id)
            endedSessions.removeValue(forKey: id)
            remindedTurn.removeValue(forKey: id)
        }
        noteAttentionTransitions()
        refreshIconTicker()
    }

    var isPaused = false

    /// Tools the user has switched off in Settings. A tool that is off is
    /// not shown at all: no rows, no hook events, nothing.
    ///
    /// This exists because the Providers switch used to control only the
    /// approval bridge, so turning Claude Code off removed its hooks and
    /// left every Claude row exactly where it was. Nobody reads a switch
    /// next to a tool's name as "keep listing it, just answer prompts
    /// differently".
    private(set) var disabledTools: Set<AgentTool> = []

    /// Injectable so tests cannot write to the real preferences. They did:
    /// the first version read and wrote UserDefaults.standard directly, and
    /// running the suite switched Grok Build off in the shipping app.
    @ObservationIgnored private let defaults: UserDefaults

    func isEnabled(_ tool: AgentTool) -> Bool { !disabledTools.contains(tool) }

    func setToolEnabled(_ tool: AgentTool, _ enabled: Bool) {
        if enabled { disabledTools.remove(tool) } else { disabledTools.insert(tool) }
        defaults.set(disabledTools.map(\.rawValue), forKey: Self.disabledToolsKey)
        if !enabled {
            // Drop what is already on screen, rather than waiting for a
            // poll that will now never come.
            sessions.removeAll { $0.tool == tool }
            for id in hookOverrides.keys where !sessions.contains(where: { $0.id == id }) {
                hookOverrides.removeValue(forKey: id)
            }
        }
        noteAttentionTransitions()
        refreshIconTicker()
    }

    /// Live state of the hook bridge, surfaced in Settings. Set by HookServer.
    var hookServerState: HookServer.ServerState = .starting

    // Drives the menu bar glyph's animation frame. The MenuBarExtra label
    // only reliably re-renders on observable data changes, so the ticker
    // lives here rather than in the label view. Fill cycle steps at 450ms
    // per the icon spec; the attention flash alternates at 1Hz. The phase
    // only advances (and so the label only re-renders) while animating.
    private(set) var iconPhase = 0
    @ObservationIgnored private var iconTicker: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.stringArray(forKey: Self.disabledToolsKey) ?? []
        self.disabledTools = Set(raw.compactMap(AgentTool.init(rawValue:)))
        // No ticker until something needs to animate; see refreshIconTicker.
    }

    private static let disabledToolsKey = "disabledTools"

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

    /// Whether any agent is actually doing work right now. Deliberately NOT
    /// the Active section: that section also holds finished turns whose
    /// process is still open, and keying the icon off it kept the fill cycle
    /// running whenever any agent was merely sitting in a terminal.
    var anyWorking: Bool { sessions.contains { $0.status.isActive } }
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
        return anyWorking && !isPaused
    }

    // Called by monitors.
    func upsert(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            var merged = session
            merged.startedAt = sessions[index].startedAt
            merged.accountLabel = session.accountLabel ?? sessions[index].accountLabel
            // Monitors never learn a title (it arrives on hook payloads), so
            // without this every poll would wipe one the hooks had supplied.
            merged.title = session.title ?? sessions[index].title
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

    /// Replaces one tool's sessions ON ONE HOST with a freshly discovered
    /// set: upserts each and drops that tool and host's sessions that no
    /// longer exist. `host` is nil for this Mac, so a monitor that omits it
    /// claims the local rows and DELETES them; every remote monitor must
    /// pass its own host. Hook
    /// overrides win over transcript-derived status: sticky ones (pending
    /// approvals) until resolved, others for a grace window that covers
    /// polling lag.
    func sync(tool: AgentTool, host: String? = nil, sessions incoming: [AgentSession]) {
        guard isEnabled(tool) else {
            if sessions.contains(where: { $0.tool == tool && $0.host == host }) {
                sessions.removeAll { $0.tool == tool && $0.host == host }
                refreshIconTicker()
            }
            return
        }
        // Upserts and overrides are intermediate states. Publish attention
        // only after the entire snapshot, dismissals and hooks have settled.
        isSyncing = true
        defer {
            isSyncing = false
            noteAttentionTransitions()
            noteIdleTurns()
            refreshIconTicker()
        }
        let incomingIds = Set(incoming.map(\.id))
        for session in incoming { upsert(session) }
        if host == nil, Self.provesProcessPerSession.contains(tool) {
            // A pinned prompt for a tool answered at its terminal cannot
            // outlive the process: nothing holds it, and the row would keep
            // offering Approve and Deny for a terminal that is gone (or, by
            // pid reuse, someone else's). These tools prove liveness per
            // session, so a row this poll found dead lets its pin go.
            for session in incoming where !session.processAlive {
                if hookOverrides[session.id]?.sticky == true {
                    hookOverrides.removeValue(forKey: session.id)
                }
            }
        }
        if host == nil, tool == .kimiCode || tool == .bearCode {
            // The Kimi family's liveness is a count per directory, so a
            // session that died at its prompt can still read as alive
            // beside another. Its pin goes once the process its own hook
            // came from is gone (SessionProcessRegistry).
            let rows = Set(sessions.filter { $0.tool == tool && $0.host == nil }.map(\.id))
            for (id, pin) in hookOverrides where pin.sticky && rows.contains(id) && boundProcessGone(id) {
                hookOverrides.removeValue(forKey: id)
            }
        }
        sessions.removeAll {
            $0.tool == tool && $0.host == host
                && !incomingIds.contains($0.id) && hookOverrides[$0.id] == nil
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
        for (id, acknowledged) in acknowledgedAt {
            guard let session = sessions.first(where: { $0.id == id }) else { continue }
            if (session.status.isActive && session.lastActivityAt > acknowledged.at)
                || (session.status.needsAttention && !acknowledged.matches(session)) {
                // The dismissal is over. Keep alert history: a hook may
                // already have announced the new request before this poll.
                acknowledgedAt.removeValue(forKey: id)
            } else if case .waitingInput(let prompt) = session.status {
                update(id: id) { $0.status = .done(summary: prompt) }
            }
        }
        pruneSessionRecords()
        reapplyHookOverrides()
        // After the overrides: a sticky PermissionRequest pin reapplied
        // here would otherwise put the answered prompt's Approve back.
        holdAnsweredPrompts()
        pruneAlertRecords()
    }

    /// Prompts answered by keystrokes, by row, with the request id they
    /// answered. Codex records nothing until the approved command has run,
    /// so its rollout keeps describing the same prompt for as long as the
    /// command takes, and the row would offer Approve again under the same
    /// text: a second "y" lands on whatever is on screen by then.
    ///
    /// The same holds for every tool answered by keys. A selector press
    /// left the row offering Approve under the same text until the next
    /// poll, and a second click then approved whatever prompt the agent
    /// had drawn next. A prompt with no event id is matched by its text.
    @ObservationIgnored private var answeredPrompts:
        [UUID: (eventID: String?, prompt: ApprovalPrompt, allow: Bool, tool: AgentTool)] = [:]

    /// Local sessions whose keystroke answer is on its way. A second click
    /// meanwhile would read the same screen and could press into whatever
    /// the first answer left behind, so it sends nothing.
    @ObservationIgnored private(set) var answersInFlight: Set<UUID> = []

    /// Keys answering a prompt reached its terminal. Until the session's
    /// own state moves past that prompt, the row says what was sent.
    ///
    /// It does not say the command is running. The keys reaching the
    /// terminal is iTerm2 or tmux writing a byte, not Codex accepting it:
    /// a "y" that landed before the prompt was drawn, or in the composer,
    /// leaves Codex waiting. So the row stays in Needs you, as the rollout
    /// says it should (an approved long-running command keeps its row
    /// orange until its output line lands), with no second Approve, and
    /// points at the terminal in case Codex is still asking.
    ///
    /// `answered` is the prompt the keys were aimed at. When the row has
    /// already moved on to another prompt, that one was not answered and
    /// keeps its buttons.
    func noteKeysAnswered(_ sessionID: UUID, allow: Bool, answered: ApprovalPrompt? = nil) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              case .waitingApproval(let prompt) = session.status,
              answered == nil || answered == prompt
        else { return }
        answeredPrompts[sessionID] = (session.attentionEventID, prompt, allow, session.tool)
        noteKeysSent(sessionID, allow: allow, tool: session.tool)
    }

    /// What a row whose answer went out by keystroke says until the
    /// session moves past the prompt.
    nonisolated static func keysSentReason(allow: Bool, tool: AgentTool = .codex) -> String {
        if tool == .codex {
            return allow
                ? "Approve was sent to the terminal. Codex shows this request until the command finishes. If it is still asking, answer it in the terminal."
                : "Deny was sent to the terminal. If Codex is still asking, answer it in the terminal."
        }
        return allow
            ? "Approve was sent to the terminal. If \(tool.label) is still asking, answer it in the terminal."
            : "Deny was sent to the terminal. If \(tool.label) is still asking, answer it in the terminal."
    }

    private func noteKeysSent(_ id: UUID, allow: Bool, tool: AgentTool) {
        update(id: id) {
            $0.status = .waitingApproval(command: .unreadable(Self.keysSentReason(allow: allow, tool: tool)))
        }
    }

    private func holdAnsweredPrompts() {
        for (id, answered) in answeredPrompts {
            guard let session = sessions.first(where: { $0.id == id }),
                  case .waitingApproval(let prompt) = session.status,
                  answered.eventID.map({ $0 == session.attentionEventID })
                    ?? (session.attentionEventID == nil && prompt == answered.prompt)
            else {
                // The prompt settled, or a different one is asking.
                answeredPrompts.removeValue(forKey: id)
                continue
            }
            noteKeysSent(id, allow: answered.allow, tool: answered.tool)
        }
    }

    /// Whether `session`, as a row showed it, is still the request the
    /// store holds for that session and has not been answered. A click
    /// lands on the row as it was drawn, which can be a poll behind: the
    /// request it showed may have been answered, or replaced by another
    /// whose options read the same, and an answer for the old one must
    /// not land on the new one.
    func isStillAsking(_ session: AgentSession) -> Bool {
        guard case .waitingApproval(let shown) = session.status else { return false }
        if let current = sessions.first(where: { $0.id == session.id }) {
            guard case .waitingApproval(let prompt) = current.status, prompt == shown else { return false }
        }
        return answeredPrompts[session.id] == nil
    }

    /// Forgets bookkeeping for sessions the store no longer holds, so a
    /// long-running app does not accumulate entries for sessions that aged
    /// out of discovery.
    private func pruneSessionRecords() {
        let known = Set(sessions.map(\.id))
        endedSessions = endedSessions.filter { known.contains($0.key) }
        acknowledgedAt = acknowledgedAt.filter { known.contains($0.key) }
        remindedTurn = remindedTurn.filter { known.contains($0.key) }
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
        // Only sessions the store no longer holds at all. Dropping the
        // record for a session that merely stopped waiting is what caused
        // the repeat: it went idle for a cycle, forgot it had been
        // announced, and announced itself again on the next one.
        let known = Set(sessions.map(\.id))
        alertedStatus = alertedStatus.filter { known.contains($0.key) }
    }

    // MARK: - Hook events

    static let hookGrace: TimeInterval = 15

    /// Local tools whose discovery proves a process for each session (a
    /// pid record held to its identity, a rollout or lock file held open),
    /// and whose prompts nothing holds. Not Claude Code or OpenCode, whose
    /// prompts are held decisions; not the Kimi family, whose liveness is a
    /// count per directory and can read one live session of several as
    /// dead.
    static let provesProcessPerSession: Set<AgentTool> = [.grokBuild, .codex, .antigravity]

    struct HookOverride {
        var status: SessionStatus
        var at: Date
        var sticky: Bool
        var attentionEventID: String? = nil
    }

    @ObservationIgnored private(set) var hookOverrides: [UUID: HookOverride] = [:]
    /// Whether a Kimi-family session's own process, proved by its hook,
    /// is gone. A seam for tests.
    @ObservationIgnored var boundProcessGone: (UUID) -> Bool = { SessionProcessRegistry.isGone($0) }
    @ObservationIgnored weak var approvalResponder: ApprovalResponding?

    /// Test seam. When set, a local answer is reported here instead of
    /// being carried out, so a test can prove which sessions would have
    /// driven this Mac's terminal without ever driving it.
    @ObservationIgnored var localAnswerObserver: ((AgentSession, ApprovalRoute) -> Void)?

    /// The same for replies: a local reply is reported here, with its text,
    /// instead of being pasted into this Mac's terminal.
    @ObservationIgnored var localReplyObserver: ((AgentSession, String) -> Void)?

    /// Answers rows that have a host. Weak because the app owns it.
    @ObservationIgnored weak var remoteActions: RemoteActing?

    /// Moves whenever a relayed hold starts or ends. Whether a remote row
    /// can be answered depends on HookServer's holds, which nothing
    /// observes, and a hold that ends at its timeout changes no row: the
    /// row keeps its prompt. Reading this from a view is what makes that
    /// row swap its buttons for the terminal note.
    var remoteHoldRevision = 0

    /// The same for panes: moves when a poll finds a process in a different
    /// pane, or none, and when a gap makes the last pane map untrustworthy.
    /// A row's pid can stay the same while its pane comes and goes.
    private(set) var remotePaneRevision = 0

    func noteRemotePanesChanged() {
        remotePaneRevision &+= 1
    }

    /// How a remote row's prompt can be answered, for the view. Reads both
    /// revisions so a view that asks is redrawn when a hold or a pane comes
    /// or goes.
    func remoteAnswerability(for session: AgentSession) -> RemoteAnswerability {
        _ = remoteHoldRevision
        _ = remotePaneRevision
        return remoteActions?.answerability(for: session) ?? .terminalOnly
    }

    /// Whether the row offers Reply, for the view. A local row always
    /// does; its status decides the rest. A remote row only while its
    /// session sits in a tmux pane SwarmBar can type into, which moves with
    /// the pane revision and the host's reachability.
    func canReply(_ session: AgentSession) -> Bool {
        guard session.host != nil else { return true }
        _ = remotePaneRevision
        return remoteActions?.canReply(session) ?? false
    }

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
    @ObservationIgnored private var acknowledgedAt: [UUID: AlertRecord] = [:]

    func acknowledge(_ session: AgentSession) {
        guard case .waitingInput(let prompt) = session.status else { return }
        acknowledgedAt[session.id] = AlertRecord(session)
        clearHookOverride(sessionID: session.id)
        update(id: session.id) { $0.status = .done(summary: prompt) }
    }

    func applyHookEvent(
        sessionID: UUID,
        tool: AgentTool,
        status: SessionStatus,
        sticky: Bool,
        cwd: String?,
        accountLabel: String?,
        title: String? = nil,
        host: String? = nil
    ) {
        // Hooks arrive independently of polling, so a disabled tool would
        // otherwise reappear the moment one of its agents did anything.
        guard isEnabled(tool) else { return }
        let eventID = status.needsAttention ? UUID().uuidString : nil
        hookOverrides[sessionID] = HookOverride(
            status: status, at: .now, sticky: sticky, attentionEventID: eventID)
        if sessions.contains(where: { $0.id == sessionID }) {
            update(id: sessionID) { session in
                session.status = status
                session.attentionEventID = eventID
                session.lastActivityAt = .now
                if let accountLabel { session.accountLabel = accountLabel }
                // Only overwrite with a real value: a later hook that
                // carries no title must not erase one an earlier hook gave.
                if let title, !title.isEmpty { session.title = title }
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
                accountLabel: accountLabel,
                // A row a relayed hook creates belongs to its host from the
                // start, so it never offers this Mac's terminal actions.
                host: host,
                attentionEventID: eventID
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
            update(id: id) {
                $0.status = override.status
                $0.attentionEventID = override.attentionEventID
            }
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

    @ObservationIgnored private var isSyncing = false

    private struct AlertRecord {
        var status: SessionStatus
        var at: Date
        var eventID: String?
        var recentEventIDs: [String]

        init(_ session: AgentSession, previousEventIDs: [String] = []) {
            status = session.status
            at = session.lastActivityAt
            eventID = session.attentionEventID
            // Keep a bounded history across hook/poll handoffs. A delayed
            // snapshot can replay a question older than the latest alert.
            recentEventIDs = Array((previousEventIDs + [session.attentionEventID].compactMap { $0 }).suffix(32))
        }

        func matches(_ session: AgentSession) -> Bool {
            if let eventID, let incoming = session.attentionEventID {
                return eventID == incoming
            }
            return status == session.status && session.lastActivityAt <= at
        }
    }

    /// Identified requests survive metadata writes and idle flicker.
    /// Providers without event identity retain timestamp-based alerts:
    /// their snapshots cannot distinguish identical successive requests
    /// from bookkeeping, so status-only deduplication would lose requests.
    @ObservationIgnored private var alertedStatus: [UUID: AlertRecord] = [:]

    private func noteAttentionTransitions() {
        guard !isSyncing else { return }
        for session in sessions where session.status.needsAttention {
            if let last = alertedStatus[session.id] {
                if let eventID = session.attentionEventID,
                   last.recentEventIDs.contains(eventID) { continue }
                // With a provider event id, even identical wording in two
                // turns is distinct, and an old polled event stays old.
                let identified = last.eventID != nil && session.attentionEventID != nil
                if !identified {
                    guard session.lastActivityAt > last.at else { continue }
                }
            }
            alertedStatus[session.id] = AlertRecord(session,
                previousEventIDs: alertedStatus[session.id]?.recentEventIDs ?? [])
            attentionAlertHandler?(session)
        }
    }

    // MARK: - Idle turn reminders

    /// When this store started. A turn that ended before launch was never
    /// seen ending, so it is not announced: opening the app must not fire a
    /// banner for every agent that was already sitting idle.
    @ObservationIgnored var launchedAt = Date.now

    /// How long a finished turn waits, process still open, before it counts
    /// as waiting on the user. Matches Claude Code's own idle_prompt, and
    /// means no banner when the user is already at the terminal.
    static let idleReminderDelay: TimeInterval = 60

    /// Wired by the app to post "waiting on you". Separate from
    /// attentionAlertHandler because the row's status does not change: the
    /// turn is still Done in Active, it has just been sitting there.
    @ObservationIgnored var idleTurnHandler: ((AgentSession) -> Void)?

    /// The turn (its end time) each session was last reminded about, so a
    /// turn is announced once and the next turn earns its own reminder.
    @ObservationIgnored private var remindedTurn: [UUID: Date] = [:]

    /// A finished turn whose process is still open is an agent waiting on
    /// the user, for every tool. Six of seven tools only call that
    /// "waiting" when the last message holds a question mark, which caught
    /// about a quarter of real turn endings, so this keys on the state every
    /// monitor reports instead of on any one provider's signal. A turn
    /// already announced by the question rule is not .done, and a dismissed
    /// one carries an acknowledgement, so neither is announced twice.
    func noteIdleTurns(now: Date = .now) {
        for session in sessions {
            guard case .done = session.status, session.processAlive else { continue }
            let endedAt = session.lastActivityAt
            guard endedAt > launchedAt,
                  now.timeIntervalSince(endedAt) >= Self.idleReminderDelay,
                  remindedTurn[session.id] != endedAt,
                  acknowledgedAt[session.id] == nil
            else { continue }
            remindedTurn[session.id] = endedAt
            idleTurnHandler?(session)
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
        // The row as drawn may be a poll behind the request it answers.
        guard isStillAsking(session) else { return }
        // A request the row could not show whole is never approved from
        // it, whatever the caller: the row offers the terminal instead,
        // and this is the backstop for any path that forgets.
        guard command.offersApprove else {
            if session.host == nil, session.projectPath != nil { openInTerminal(session) }
            return
        }
        if approvalResponder?.resolveApproval(sessionID: session.id, allow: true) == true {
            noteAnswered(session.id, command: command, allow: true)
            return
        }
        // Every route below reaches into a terminal on THIS Mac, which a
        // remote session is not in. Its keys go to its own tmux pane on its
        // host instead, or nowhere.
        guard session.host == nil else {
            remoteActions?.answer(session, allow: true)
            return
        }
        follow(
            ApprovalRouter.route(tool: session.tool, allow: true, in: environment(for: session)),
            for: session, allow: true,
            choose: TuiPromptLayout.approveOnceOption(in:),
            mockStatus: .runningTool(activity: running(command))
        )
    }

    func deny(_ session: AgentSession) {
        guard case .waitingApproval(let command) = session.status else { return }
        guard isStillAsking(session) else { return }
        if approvalResponder?.resolveApproval(sessionID: session.id, allow: false) == true {
            noteAnswered(session.id, command: command, allow: false)
            return
        }
        guard session.host == nil else {
            remoteActions?.answer(session, allow: false)
            return
        }
        follow(
            ApprovalRouter.route(tool: session.tool, allow: false, in: environment(for: session)),
            for: session, allow: false,
            choose: TuiPromptLayout.rejectOption(in:),
            mockStatus: .working(activity: "Rethinking approach without that command…")
        )
    }

    private func environment(for session: AgentSession) -> ApprovalRouter.Environment {
        .init(
            grokKeystrokes: Self.grokKeystrokesEnabled,
            antigravityKeystrokes: Self.antigravityKeystrokesEnabled,
            hasProjectPath: session.projectPath != nil
        )
    }

    /// Carries out whatever the router chose. Which option a selector route
    /// aims at is the caller's, since approve and deny differ only there.
    private func follow(
        _ route: ApprovalRoute,
        for session: AgentSession,
        allow: Bool,
        choose: @escaping @Sendable (String) -> TuiPromptLayout.Option?,
        mockStatus: SessionStatus
    ) {
        if let localAnswerObserver {
            localAnswerObserver(session, route)
            return
        }
        switch route {
        case .keys, .numberedSelector, .navigateSelector:
            answerByKeys(session, route: route, allow: allow, choose: choose)
        case .focusTerminal:        openInTerminal(session)
        case .mockTransition:       update(id: session.id) { $0.status = mockStatus }
        }
    }

    /// Presses a keystroke answer into a session on this Mac. Carries out
    /// a key route and reports whether the keys were confirmed sent.
    typealias KeystrokeAnswerer = @Sendable (
        AgentSession, ApprovalRoute, @escaping @Sendable (String) -> TuiPromptLayout.Option?
    ) async -> Bool

    /// Test seam: replaces the terminal with a stub, so the in-flight
    /// guard and the answered hold can be exercised without iTerm2.
    @ObservationIgnored var keystrokeAnswerer: KeystrokeAnswerer?

    /// One keystroke answer per session at a time. Once the keys are
    /// confirmed sent the row stops offering Approve and Deny for that
    /// request, until the tool's own state shows a different one.
    private func answerByKeys(
        _ session: AgentSession, route: ApprovalRoute, allow: Bool,
        choose: @escaping @Sendable (String) -> TuiPromptLayout.Option?
    ) {
        guard case .waitingApproval(let command) = session.status,
              answersInFlight.insert(session.id).inserted
        else { return }
        let answerer = keystrokeAnswerer ?? Self.answerAtTerminal
        Task {
            let sent = await answerer(session, route, choose)
            answersInFlight.remove(session.id)
            if sent { noteKeysAnswered(session.id, allow: allow, answered: command) }
        }
    }

    /// The real answerer: the route's keys, pressed into the session's
    /// own terminal, falling back to focusing it whenever the prompt
    /// cannot be confirmed.
    nonisolated static let answerAtTerminal: KeystrokeAnswerer = { session, route, choose in
        await Task.detached {
            let id = session.id, path = session.projectPath, tool = session.tool
            func giveUp() -> Bool {
                TerminalFocuser.focus(sessionID: id, tool: tool, projectPath: path)
                return false
            }
            switch route {
            case .keys(let keys):
                return TerminalFocuser.sendKeys(sessionID: id, tool: tool, projectPath: path, keys: keys)
                    ? true : giveUp()
            case .numberedSelector:
                return answerNumberedPrompt(session, choose: choose) ? true : giveUp()
            case .navigateSelector:
                return answerByNavigation(session, choose: choose) ? true : giveUp()
            case .focusTerminal, .mockTransition:
                return false
            }
        }.value
    }

    /// The row after an answer was delivered, by a held reply or by keys
    /// a helper confirmed it pressed.
    private func noteAnswered(_ id: UUID, command: ApprovalPrompt, allow: Bool) {
        update(id: id) {
            $0.status = allow
                ? .runningTool(activity: running(command))
                : .working(activity: "Rethinking after deny…")
        }
    }

    /// A remote answer's keys landed. The answer took a round trip, so the
    /// row is moved on only if it is still asking the SAME question: a poll
    /// that has already seen the prompt settle knows better than this does,
    /// and a row now asking about another command was not answered.
    func noteRemoteAnswerSent(_ session: AgentSession, allow: Bool) {
        guard case .waitingApproval(let answered) = session.status,
              let current = sessions.first(where: { $0.id == session.id }),
              case .waitingApproval(let command) = current.status,
              command == answered
        else { return }
        // Held until the host's own state moves past the prompt, as on
        // this Mac: the next snapshot can still describe it, and a second
        // click would answer whatever the agent drew next.
        noteKeysAnswered(session.id, allow: allow, answered: command)
    }

    private func running(_ command: ApprovalPrompt) -> String {
        "Running \(ApprovalPreviewText.firstWord(command))"
    }

    /// The settings toggle for Grok's remote answers; off means Approve
    /// and Deny just focus the terminal.
    static var grokKeystrokesEnabled: Bool {
        (UserDefaults.standard.object(forKey: "grokKeystrokeAnswers") as? Bool) ?? true
    }

    /// The same escape hatch for Antigravity. Its answers are keystrokes
    /// too, so it gets the same off switch, and off means Approve and Deny
    /// just focus the terminal.
    static var antigravityKeystrokesEnabled: Bool {
        (UserDefaults.standard.object(forKey: "antigravityKeystrokeAnswers") as? Bool) ?? true
    }

    /// Reads the session's terminal, picks the option matching the
    /// intent, and presses that number, re-confirming the label at that
    /// number in the same script. False when the screen can't be read or
    /// no matching option is on it, so a misread never sends a keystroke
    /// to an unknown selector.
    private nonisolated static func answerNumberedPrompt(
        _ session: AgentSession,
        choose: @Sendable (String) -> TuiPromptLayout.Option?
    ) -> Bool {
        let id = session.id, path = session.projectPath, tool = session.tool
        guard let screen = TerminalFocuser.screenText(sessionID: id, tool: tool, projectPath: path),
              let option = choose(screen)
        else { return false }
        // The prompt moved or the terminal is gone: never press a digit
        // into an unverified selector.
        return TerminalFocuser.answerNumbered(
            sessionID: id, tool: tool, projectPath: path,
            number: option.number, expectedLabel: option.label) == .sent
    }

    /// Reads the selector, works out the distance from the cursor to the
    /// option wanted, and walks there with arrow keys.
    ///
    /// Antigravity's prompt advertises only "↑/↓ Navigate · enter Select",
    /// so unlike the Kimi family there is no evidence it takes a digit at
    /// all, and a digit is what once turned a Grok deny into an approve.
    /// Every step here is computed from the screen: which options exist,
    /// which one the cursor is on, and therefore how far to move. Nothing
    /// about the layout is assumed, so a redesigned prompt falls through
    /// to focusing the terminal instead of pressing into the unknown.
    private nonisolated static func answerByNavigation(
        _ session: AgentSession,
        choose: @Sendable (String) -> TuiPromptLayout.Option?
    ) -> Bool {
        let id = session.id, path = session.projectPath, tool = session.tool
        guard let screen = TerminalFocuser.screenText(sessionID: id, tool: tool, projectPath: path),
              let option = choose(screen)
        else { return false }
        if tool == .antigravity {
            guard case .waitingApproval(let shown) = session.status,
                  AntigravityAnswerCheck.mayAnswer(
                    shown: shown, screen: screen,
                    pending: AntigravityAnswerCheck.livePending(sessionID: id))
            else { return false }
        }
        let selector = TuiPromptLayout.selector(in: screen)
        guard let cursor = selector.cursor,
              let cursorLine = selector.cursorLine,
              let move = TuiPromptLayout.navigation(from: cursor, to: option.number)
        else { return false }
        return TerminalFocuser.answerByNavigation(
            sessionID: id, tool: tool, projectPath: path,
            key: move.key, presses: move.presses,
            expectedCursorLine: cursorLine, expectedLabel: option.label) == .sent
    }

    // MARK: - Inline reply

    /// The session whose reply composer is open, if any. The popover drills
    /// into the composer when this is set.
    var replyingTo: UUID?

    /// Whether a written reply can be delivered to this session. Both
    /// repliable statuses mean the turn has ended, so the tool's composer is
    /// idle and ready for text. A session that is working or running a tool
    /// has a busy TUI, and an idle one may have exited with its tty reassigned.
    nonisolated static func canReceiveReply(_ status: SessionStatus) -> Bool {
        switch status {
        case .waitingInput, .done: true
        case .working, .runningTool, .waitingApproval, .idle: false
        }
    }

    enum ReplyResult: Equatable {
        case sent
        /// Delivered nothing. The draft is still the user's to keep.
        case failed(String)
    }

    /// Sends a written reply to a live session. Re-checks the status at send
    /// time rather than trusting what the row said when the composer opened,
    /// since the session may have started working while the user typed.
    func sendReply(
        _ session: AgentSession,
        text: String,
        completion: @escaping @MainActor (ReplyResult) -> Void
    ) {
        // Controls the composer cannot show (ESC above all) never reach a
        // terminal, here or on a host, and a reply that was nothing else is
        // empty.
        let text = RemoteAnswerPlan.pasteText(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failed("Nothing to send.")); return
        }
        guard let current = sessions.first(where: { $0.id == session.id }) else {
            completion(.failed("That session is gone.")); return
        }
        guard Self.canReceiveReply(current.status) else {
            completion(.failed("That session is busy now, so nothing was sent."))
            return
        }

        // A remote session's terminal is on its host. Pasting here would
        // find a same-named directory on this Mac, if anything.
        if let host = session.host {
            guard let remoteActions else {
                completion(.failed("This session isn't in tmux on \(host), so reply in its terminal."))
                return
            }
            remoteActions.reply(current, text: text, completion: completion)
            return
        }
        if let localReplyObserver {
            localReplyObserver(session, text)
            return
        }

        let id = session.id
        let path = session.projectPath
        let tool = session.tool
        Task.detached {
            let outcome = TerminalFocuser.sendReply(
                sessionID: id, tool: tool, projectPath: path, text: text)
            await MainActor.run {
                switch outcome {
                case .sent:
                    self.noteReplySent(id)
                    completion(.sent)
                case .pasteNotVisible:
                    TerminalFocuser.focus(sessionID: id, tool: tool, projectPath: path)
                    completion(.failed(
                        "The text did not appear in the composer, so nothing was submitted. Check the terminal."))
                case .noTerminal:
                    completion(.failed(
                        "Could not reach this session's terminal. Inline reply needs iTerm2."))
                }
            }
        }
    }

    /// A reply was submitted, here or on a host: the session's next turn
    /// has started.
    func noteReplySent(_ id: UUID) {
        update(id: id) {
            $0.status = .working(activity: "Working on your reply…")
        }
    }

    /// The decision half of `openInTerminal`, pulled out so it is testable
    /// without driving TerminalFocuser's real AppleScript and pgrep calls.
    /// Delegates to `SessionRowInteraction.allowsLocalTerminalActions`,
    /// which the views already consult for the same gate, so there is one
    /// rule rather than two that could drift apart.
    static func canOpenInTerminal(_ session: AgentSession) -> Bool {
        SessionRowInteraction.allowsLocalTerminalActions(host: session.host)
    }

    /// Gated on `session.host` even though every row-level call site already
    /// checks `SessionRowInteraction.allowsLocalTerminalActions` before
    /// reaching here. That gate lives in the views, and this method has
    /// another caller that is not a view: the notification click handler in
    /// SwarmBarApp, which resolves a session by id and calls straight in.
    /// Every channel TerminalFocuser has (open -a iTerm, cwd matching,
    /// AppleScript) targets THIS Mac, so acting on a remote session focuses
    /// the wrong machine, silently and convincingly, rather than doing
    /// nothing. Checking here too makes the guarantee structural instead of
    /// depending on every present and future call site remembering it.
    /// Phase 2 replaces this with a remote channel; until then, doing
    /// nothing for a remote session is strictly better than focusing a
    /// same-named local directory and implying it is the session in question.
    func openInTerminal(_ session: AgentSession) {
        guard Self.canOpenInTerminal(session) else {
            FocusLog.log.notice("open: skipped, remote session on \(session.host ?? "?", privacy: .public)")
            return
        }
        let id = session.id
        let path = session.projectPath
        let tool = session.tool
        Task.detached {
            TerminalFocuser.focus(sessionID: id, tool: tool, projectPath: path)
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
