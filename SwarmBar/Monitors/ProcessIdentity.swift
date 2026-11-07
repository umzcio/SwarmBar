import Darwin
import Foundation

/// Whether a pid an agent wrote into its own state file still belongs to
/// that agent's process.
///
/// A recorded pid outlives its process. When the process exits the number
/// goes back into the pool, and macOS hands pids out in sequence and wraps,
/// so in time another process of the same user gets it. kill(pid, 0) says
/// only that SOME process of this user has the number, so a stale record
/// passed it and bound the session to a stranger's terminal: Approve walked
/// another agent's selector, Reply pasted into it.
///
/// A recorded pid is accepted here only when the live process is
/// verifiably the tool's: it runs as this user, its name is the tool's,
/// and it started no later than the record that names it (a process cannot
/// write a record before it exists, and a reused pid belongs to a process
/// that started after the original died). Anything that cannot be proved
/// reads as not the tool's process, which leaves the session without a
/// terminal, so actions on it fall back to focusing rather than typing.
enum ProcessIdentity {
    struct Facts: Equatable, Sendable {
        /// The kernel's short name, the executable's file name.
        var commandName: String
        /// The executable path and argv[0], from the process's arguments.
        /// argv[0] is what a renamed process (process.title) shows, and what
        /// a native Claude Code install, whose executable is named after its
        /// version, is called by.
        var executablePath: String?
        var argv0: String?
        var uid: uid_t
        var startedAt: Date
    }

    /// Allowance between the kernel's start time and the tool's own
    /// timestamp, which are taken by different clocks at different
    /// precisions. A reused pid would have to start within this long of
    /// the record, after the original process had already died, to slip
    /// through.
    nonisolated static let slack: TimeInterval = 5

    nonisolated static let claudeNames: Set<String> = ["claude"]
    nonisolated static let grokNames: Set<String> = ["grok"]

    /// The pure half: whether `facts` describe a process of one of `names`,
    /// owned by `uid`, started no later than `recordedAt`. No record time
    /// means nothing to prove the start against, so it is not accepted.
    nonisolated static func matches(
        _ facts: Facts, names: Set<String>, recordedAt: Date?, uid: uid_t = getuid()
    ) -> Bool {
        guard let recordedAt, facts.uid == uid,
              facts.startedAt <= recordedAt.addingTimeInterval(slack)
        else { return false }
        let candidates = [facts.commandName, facts.argv0, facts.executablePath]
            .compactMap { $0 }
            .map { ($0 as NSString).lastPathComponent }
        return candidates.contains { names.contains($0) }
    }

    /// The live check: `pid`'s facts, judged by `matches`.
    nonisolated static func isProcess(_ pid: Int, names: Set<String>, recordedAt: Date?) -> Bool {
        guard let facts = facts(pid: pid) else { return false }
        return matches(facts, names: names, recordedAt: recordedAt)
    }

    /// The kernel's record of `pid`, or nil when there is no such process.
    /// sysctl, not ps: discovery asks this every poll for every recorded
    /// pid, and a process launch per question would cost more than the
    /// kill(pid, 0) it replaces by orders of magnitude.
    nonisolated static func facts(pid: Int) -> Facts? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == Int32(pid)
        else { return nil }
        let start = info.kp_proc.p_starttime
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let args = arguments(pid: pid)
        return Facts(
            commandName: name,
            executablePath: args?.executable,
            argv0: args?.argv0,
            uid: info.kp_eproc.e_ucred.cr_uid,
            startedAt: Date(timeIntervalSince1970:
                TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        )
    }

    /// The executable path and argv[0] from KERN_PROCARGS2: an int argc,
    /// the executable path, NUL padding, then the argument strings. This is
    /// where ps reads a process's command line, so a title the process set
    /// for itself shows here as it does there.
    private nonisolated static func arguments(pid: Int) -> (executable: String, argv0: String?)? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var maxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maxMib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var length = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0,
              length > MemoryLayout<Int32>.size
        else { return nil }
        let bytes = buffer[MemoryLayout<Int32>.size..<length]
        guard let pathEnd = bytes.firstIndex(of: 0) else { return nil }
        let executable = String(decoding: bytes[bytes.startIndex..<pathEnd], as: UTF8.self)
        guard let argStart = bytes[pathEnd...].firstIndex(where: { $0 != 0 }) else {
            return (executable, nil)
        }
        let argEnd = bytes[argStart...].firstIndex(of: 0) ?? bytes.endIndex
        return (executable, String(decoding: bytes[argStart..<argEnd], as: UTF8.self))
    }
}
