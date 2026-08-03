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
                let attention = (self?.attentionCount ?? 0) > 0
                let active = self?.anyActive ?? false
                try? await Task.sleep(for: .milliseconds(attention ? 500 : 450))
                guard let self else { return }
                if self.attentionCount > 0 || (self.anyActive && !self.isPaused) {
                    self.iconPhase &+= 1
                }
            }
        }
    }

    // Derived slices the popover renders.
    var attention: [AgentSession] { sessions.filter { $0.status.needsAttention } }
    var active:    [AgentSession] { sessions.filter { $0.status.isActive } }
    var recent:    [AgentSession] { sessions.filter { !$0.status.needsAttention && !$0.status.isActive } }

    var anyActive: Bool { !active.isEmpty }
    var attentionCount: Int { attention.count }

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
        reapplyHookOverrides()
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
            answerGrokPrompt(session, keys: Array(repeating: "DOWN", count: 8) + ["UP", "\n"])
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
            answerGrokPrompt(session, keys: Array(repeating: "DOWN", count: 8) + ["\n", "\n"])
            return
        }
        if session.projectPath != nil { openInTerminal(session); return }
        update(id: session.id) { $0.status = .working(activity: "Rethinking approach without that command…") }
    }

    private func answerGrokPrompt(_ session: AgentSession, keys: [String]) {
        let id = session.id
        let path = session.projectPath
        Task.detached {
            if !TerminalFocuser.sendKeys(sessionID: id, keys: keys) {
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
