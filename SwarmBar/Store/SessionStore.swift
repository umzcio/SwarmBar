import Foundation
import Observation

/// Single source of truth. Monitors push updates in; views observe.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []
    var isPaused = false

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
            sessions[index] = merged
        } else {
            sessions.insert(session, at: 0)
        }
    }

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    func update(id: UUID, _ mutate: (inout AgentSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
    }

    // Called by row buttons. In phase 1 these transition mock state directly;
    // real monitors (phase 3+) route through each tool's control channel and
    // confirm the new state from the tool side.
    func approve(_ session: AgentSession) {
        guard case .waitingApproval(let command) = session.status else { return }
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        update(id: session.id) { $0.status = .runningTool(activity: "Running \(executable)") }
    }

    func deny(_ session: AgentSession) {
        guard case .waitingApproval = session.status else { return }
        update(id: session.id) { $0.status = .working(activity: "Rethinking approach without that command…") }
    }

    func openForReply(_ session: AgentSession) {
        guard case .waitingInput = session.status else { return }
        update(id: session.id) { $0.status = .working(activity: "Continuing with your answer…") }
    }

    func pauseAll() { }
}
