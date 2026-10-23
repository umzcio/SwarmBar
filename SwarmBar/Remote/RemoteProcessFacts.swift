import Foundation

/// A remote host's process table, as the helper shipped it, answering the
/// questions discovery asks of this Mac's. Discovery runs against the
/// mirror, so every directory it asks about is a mirror path; each one is
/// turned back into the host's own path before it is matched, because the
/// process records name the host's files.
///
/// Where the local answers come from parsing lsof output, these build the
/// same output from the records and hand it to the same parser, so the
/// rules for which files count stay in one place.
struct RemoteProcessFacts: ProcessFacts {
    private let processes: [RemoteProcessRecord]
    private let mirror: RemoteMirror

    /// Pids whose open files the helper could not read. Their `open` is
    /// empty because it is unknown, not because they hold nothing, so
    /// RemoteDiscovery reports them rather than letting the gap pass.
    let unreadablePids: [Int]

    nonisolated init(processes: [RemoteProcessRecord], failed: Bool, mirror: RemoteMirror) {
        // When ps itself failed there is no table at all, so nothing can be
        // vouched for and every question gets an empty answer. RemoteDiscovery
        // marks every tool unverified in that case, so those answers are
        // never synced as sessions having ended.
        self.processes = failed ? [] : processes
        self.mirror = mirror
        self.unreadablePids = failed ? [] : processes.filter(\.openFailed).map(\.pid)
    }

    nonisolated func isAlive(_ pid: Int) -> Bool {
        processes.contains { $0.pid == pid }
    }

    nonisolated func directoryCounts(processNames: [String]) -> [String: Int] {
        counts(processes.filter { processNames.contains($0.comm) })
    }

    /// The helper already resolves an interpreter-launched BearCode to the
    /// name `bearcode`, so the pattern only matters for a record it could
    /// not resolve. Both are tried, as locally.
    nonisolated func directoryCounts(processName: String, orCommandPattern: String) -> [String: Int] {
        counts(processes.filter { $0.comm == processName || $0.args.contains(orCommandPattern) })
    }

    nonisolated func codexPidsBySessionSuffix(sessionsRoot: String) -> [String: Int] {
        guard let root = remotePath(sessionsRoot) else { return [:] }
        return TerminalFocuser.codexPids(
            inLsofOutput: lsofOutput(processes.filter { $0.comm == "codex" }),
            sessionsRoot: root)
    }

    /// Keys are the host's paths. Callers only read the last component,
    /// which is the same on both sides.
    nonisolated func heldFiles(processName: String, inDirectory: String) -> [String: Int] {
        guard let directory = remotePath(inDirectory) else { return [:] }
        return ProcessLiveness.heldFiles(
            inLsofOutput: lsofOutput(processes.filter { $0.comm == processName }),
            directory: directory)
    }

    nonisolated func cwd(pid: Int) -> String? {
        processes.first { $0.pid == pid }.flatMap { $0.cwd.isEmpty ? nil : $0.cwd }
    }

    /// The newest match, taken as the highest pid. Locally pgrep's last
    /// line is preferred for the same reason: a fresh launch in a directory
    /// is the one the user is looking at.
    nonisolated func pid(processNames: [String], cwd: String) -> Int? {
        processes
            .filter { processNames.contains($0.comm) && $0.cwd == cwd }
            .map(\.pid)
            .max()
    }

    /// The process's screen, which the helper captures only for tools that
    /// need it.
    nonisolated func screen(pid: Int) -> String? {
        processes.first { $0.pid == pid }?.screen
    }

    private nonisolated func counts(_ matching: [RemoteProcessRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in matching where !record.cwd.isEmpty {
            counts[record.cwd, default: 0] += 1
        }
        return counts
    }

    private nonisolated func remotePath(_ mirrorPath: String) -> String? {
        mirror.remote(URL(fileURLWithPath: mirrorPath))
    }

    /// `lsof -F pn` output for these records: a p line, then an n line per
    /// open file. A record whose files are unknown is left out entirely, so
    /// it can never be read as holding nothing in particular.
    private nonisolated func lsofOutput(_ records: [RemoteProcessRecord]) -> String {
        var lines: [String] = []
        for record in records where !record.openFailed {
            lines.append("p\(record.pid)")
            for path in record.open where !path.contains("\n") {
                lines.append("n\(path)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
