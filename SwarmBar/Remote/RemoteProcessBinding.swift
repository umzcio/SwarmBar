import Foundation
import Synchronization

/// Which process on a host a remote Kimi Code or BearCode session's prompt
/// came from: the remote form of SessionProcessRegistry.
///
/// Discovery can only match their processes to sessions by working
/// directory, and a session that died at its prompt kept its pinned row.
/// With another session of the tool alive in the same directory, the dead
/// row could carry the live process's pid, and Approve on it typed into the
/// live session's prompt: a request the person never saw.
///
/// The hook that raises a prompt proves the process instead. The helper
/// reads the bridge's peer off its socket, walks up to the nearest agent,
/// and relays that agent's pid and start time with the PermissionRequest
/// (peer_agent in swarmbar-helper.py). A keystroke answer then goes only
/// to that process, and only while the host's process table still shows
/// it with the same start time. A helper from before that relays no
/// process, so nothing is bound and the row only says to answer at the
/// terminal.
enum RemoteProcessBinding {
    /// The agent process a relayed hook came from, as the helper named it.
    struct Agent: Equatable, Sendable {
        var pid: Int
        var name: String
        /// The helper's process_start token, compared only with another.
        var start: String
    }

    struct Bound: Equatable, Sendable {
        var hostID: UUID
        var agent: Agent
        /// Set once a full process table from the host no longer shows the
        /// process, so its pinned prompt can go.
        var gone = false
    }

    private static let table = Mutex<[UUID: Bound]>([:])

    /// The process names the helper gives each member of the family.
    nonisolated static func names(for tool: AgentTool) -> [String] {
        switch tool {
        case .kimiCode: KimiMonitor.processNames
        case .bearCode: [KimiMonitor.BearCode.processName]
        default: []
        }
    }

    /// The tools whose remote rows are bound this way.
    nonisolated static func applies(to tool: AgentTool) -> Bool {
        tool == .kimiCode || tool == .bearCode
    }

    /// A relayed event's `agent`, or nil when it is missing or not in the
    /// shape the helper sends.
    nonisolated static func agent(from value: Any?) -> Agent? {
        guard let object = value as? [String: Any],
              let pid = object["pid"] as? Int, pid > 1,
              let name = object["name"] as? String,
              let start = object["start"] as? String, !start.isEmpty, start.count <= 64
        else { return nil }
        return Agent(pid: pid, name: name, start: start)
    }

    /// Binds a session to the process that raised its prompt, or forgets
    /// any earlier binding when the prompt names no process of this tool:
    /// a new prompt from an unknown process must not leave keys aimed at
    /// an old one. A process holds one session at a time, so a session it
    /// raised earlier (before /new, say) loses its binding.
    nonisolated static func bind(_ id: UUID, hostID: UUID, agent: Agent?, tool: AgentTool) {
        table.withLock { table in
            guard let agent, names(for: tool).contains(agent.name) else {
                table.removeValue(forKey: id)
                return
            }
            for (other, bound) in table
            where other != id && bound.hostID == hostID && bound.agent == agent {
                table.removeValue(forKey: other)
            }
            table[id] = Bound(hostID: hostID, agent: agent)
        }
    }

    nonisolated static func forget(_ id: UUID) {
        _ = table.withLock { $0.removeValue(forKey: id) }
    }

    nonisolated static func bound(_ id: UUID) -> Bound? {
        table.withLock { $0[id] }
    }

    /// The bound process's record in a host's process table while it is
    /// still that process: same pid, one of the tool's own names, and the
    /// start time recorded when it was bound. Nil for a session never
    /// bound, one bound on another host, and a record that carries no
    /// start time to compare, as from a helper that predates it.
    nonisolated static func record(
        for id: UUID, hostID: UUID, tool: AgentTool, in processes: [RemoteProcessRecord]
    ) -> RemoteProcessRecord? {
        guard let bound = bound(id), bound.hostID == hostID, !bound.gone else { return nil }
        return processes.first {
            $0.pid == bound.agent.pid && names(for: tool).contains($0.comm) && $0.started == bound.agent.start
        }
    }

    /// Marks every binding on this host whose process the table no longer
    /// shows: its pid is missing, or now names a process with another start
    /// time or name. Only a table the helper read in full can say that, so
    /// call it only when its ps did not fail. A record without a start time
    /// says nothing either way.
    nonisolated static func noteProcesses(hostID: UUID, _ processes: [RemoteProcessRecord]) {
        table.withLock { table in
            for (id, bound) in table where bound.hostID == hostID && !bound.gone {
                guard let record = processes.first(where: { $0.pid == bound.agent.pid }) else {
                    table[id]?.gone = true
                    continue
                }
                if record.comm != bound.agent.name
                    || (record.started != nil && record.started != bound.agent.start) {
                    table[id]?.gone = true
                }
            }
        }
    }

    /// Whether a session was bound to a process its host has since shown
    /// to be gone. A session never bound is not known to be gone.
    nonisolated static func isGone(_ id: UUID) -> Bool {
        bound(id)?.gone == true
    }
}
