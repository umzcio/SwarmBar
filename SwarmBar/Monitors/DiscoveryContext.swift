import Foundation

/// Every question discovery asks about running processes. Locally the
/// answers come from pgrep, lsof and kill on this Mac; for a remote host
/// they come from the process table the helper ships, read against a
/// mirror of that host's files. Keeping the questions behind one protocol
/// is what lets the same discovery code run in both places.
protocol ProcessFacts: Sendable {
    func isAlive(_ pid: Int) -> Bool
    func directoryCounts(processNames: [String]) -> [String: Int]
    func directoryCounts(processName: String, orCommandPattern: String) -> [String: Int]
    func codexPidsBySessionSuffix(sessionsRoot: String) -> [String: Int]
    func heldFiles(processName: String, inDirectory: String) -> [String: Int]
    func cwd(pid: Int) -> String?
    func pid(processNames: [String], cwd: String) -> Int?
}

/// This Mac's process table. Each method calls the code discovery called
/// before the protocol existed, unchanged, so a user with no remote hosts
/// runs exactly the same pgrep and lsof invocations, with the same flags,
/// as before.
struct LocalProcessFacts: ProcessFacts {
    nonisolated init() {}

    /// Signal 0 delivers nothing and only checks that the pid exists, which
    /// is how every liveness check here has always been made.
    nonisolated func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0
    }

    nonisolated func directoryCounts(processNames: [String]) -> [String: Int] {
        ProcessLiveness.directoryCounts(processNames: processNames)
    }

    nonisolated func directoryCounts(processName: String, orCommandPattern: String) -> [String: Int] {
        ProcessLiveness.directoryCounts(processName: processName, orCommandPattern: orCommandPattern)
    }

    nonisolated func codexPidsBySessionSuffix(sessionsRoot: String) -> [String: Int] {
        TerminalFocuser.codexPidsBySessionSuffix(sessionsRoot: sessionsRoot)
    }

    nonisolated func heldFiles(processName: String, inDirectory: String) -> [String: Int] {
        ProcessLiveness.openFiles(processName: processName, inDirectory: inDirectory)
    }

    nonisolated func cwd(pid: Int) -> String? {
        ProcessLiveness.cwd(pid: pid)
    }

    nonisolated func pid(processNames: [String], cwd: String) -> Int? {
        ProcessLiveness.pid(processNames: processNames, cwd: cwd)
    }
}

/// Where discovery looks and whom it asks. Monitors used to assume this
/// Mac's home directory and process table; taking them from a context
/// lets a remote host's mirrored state go through the very same parsers,
/// so there is one implementation of every tool's rules rather than two
/// that drift apart.
struct DiscoveryContext: Sendable {
    /// The home directory every tool's state hangs off.
    var home: URL
    var processes: any ProcessFacts
    /// A path written inside a state file (Kimi's sessionDir), to where it can be read.
    var locate: @Sendable (String) -> URL
    var screen: @Sendable (Int) -> String?
    /// Whether discovery should look up a pid for tools with no session to
    /// pid registry (Kimi, BearCode, OpenCode). That lookup costs a pgrep
    /// and an lsof per live session, and locally nothing reads `pid` from
    /// discovery: the answer path resolves its own. Paying it on every
    /// poll here would only slow the Mac down. A remote host's facts come
    /// from a table already in memory, and remote answering needs the pid.
    var resolvesPids: Bool = false

    nonisolated static func local() -> DiscoveryContext {
        DiscoveryContext(
            home: FileManager.default.homeDirectoryForCurrentUser,
            processes: LocalProcessFacts(),
            locate: { URL(fileURLWithPath: $0) },
            screen: { TerminalFocuser.screenText(pid: $0) },
            resolvesPids: false
        )
    }
}
