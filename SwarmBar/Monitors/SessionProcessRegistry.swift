import Darwin
import Foundation
import Synchronization

/// Which process a Kimi Code or BearCode session's prompt came from.
///
/// Neither tool records a session-to-process map, and their processes are
/// told apart only by working directory. That was enough to find a
/// terminal but not to say whose it was: a session that died at its prompt
/// kept its pinned row, and with one other session left in the directory,
/// the directory resolved to that other session's terminal. Approve on the
/// dead row then typed its digit into the live one's prompt, approving a
/// request the person never saw.
///
/// The hook that raises a prompt proves the process instead. Its bridge
/// reaches HookServer over a Unix socket, whose peer is the bridge's own
/// process, and the bridge runs as a child of the agent that ran the hook.
/// The first ancestor that is one of that tool's processes in the session's
/// directory is the session's process, recorded with its start time so a
/// reused pid is never mistaken for it. A keystroke answer goes only to
/// that process's terminal, and only while it is still that process.
enum SessionProcessRegistry {
    struct Bound: Equatable, Sendable {
        var pid: Int
        var startedAt: Date
    }

    private static let table = Mutex<[UUID: Bound]>([:])

    /// How far above the bridge the agent may be: curl, the bridge's shell,
    /// a hook runner's shell, the agent, with room to spare.
    nonisolated static let maxHops = 8

    nonisolated static func bind(_ id: UUID, _ bound: Bound) {
        table.withLock { $0[id] = bound }
    }

    nonisolated static func forget(_ id: UUID) {
        _ = table.withLock { $0.removeValue(forKey: id) }
    }

    nonisolated static func bound(_ id: UUID) -> Bound? {
        table.withLock { $0[id] }
    }

    /// The bound process's pid while it is still that process, or nil.
    nonisolated static func livePid(
        _ id: UUID, facts: (Int) -> ProcessIdentity.Facts? = ProcessIdentity.facts
    ) -> Int? {
        guard let bound = bound(id), isSame(bound, facts(bound.pid)) else { return nil }
        return bound.pid
    }

    /// Whether a session was bound to a process that is gone. A session
    /// never bound is not known to be gone.
    nonisolated static func isGone(
        _ id: UUID, facts: (Int) -> ProcessIdentity.Facts? = ProcessIdentity.facts
    ) -> Bool {
        guard let bound = bound(id) else { return false }
        return !isSame(bound, facts(bound.pid))
    }

    /// The same process: this user's, with the start time recorded when it
    /// was bound. A pid handed to a new process carries a later start time.
    nonisolated static func isSame(_ bound: Bound, _ facts: ProcessIdentity.Facts?, uid: uid_t = getuid()) -> Bool {
        guard let facts, facts.uid == uid else { return false }
        return abs(facts.startedAt.timeIntervalSince(bound.startedAt)) < 0.001
    }

    /// The processes above `peer`, nearest first, never `peer` itself,
    /// up to `maxHops`. Read when the bridge connects: once it has its
    /// answer it exits, and with it the chain from it to the agent.
    nonisolated static func ancestry(ofPeer peer: Int, parent: (Int) -> Int?) -> [Int] {
        var seen: Set<Int> = [peer]
        var chain: [Int] = []
        var current = peer
        for _ in 0..<maxHops {
            guard let next = parent(current), next > 1, seen.insert(next).inserted else { break }
            chain.append(next)
            current = next
        }
        return chain
    }

    /// The nearest process in `ancestry` that `isAgent` accepts.
    nonisolated static func agent(in ancestry: [Int], isAgent: (Int) -> Bool) -> Int? {
        ancestry.first(where: isAgent)
    }

    /// The parent of `pid`, from the kernel.
    nonisolated static func parent(of pid: Int) -> Int? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == Int32(pid)
        else { return nil }
        return Int(info.kp_eproc.e_ppid)
    }

    /// Binds a session to the process its hook's bridge descends from: the
    /// nearest ancestor that is one of the tool's own processes in `cwd`,
    /// judged as the terminal lookup judges them. Nothing is bound when no
    /// such ancestor exists, which leaves answers to focus the terminal.
    nonisolated static func bind(sessionID: UUID, tool: AgentTool, ancestry: [Int], cwd: String) {
        let candidates = Set(TerminalFocuser.directoryPids(tool: tool, cwd: cwd))
        guard !candidates.isEmpty,
              let pid = agent(in: ancestry, isAgent: candidates.contains),
              let facts = ProcessIdentity.facts(pid: pid), facts.uid == getuid()
        else { return }
        bind(sessionID, Bound(pid: pid, startedAt: facts.startedAt))
    }
}
