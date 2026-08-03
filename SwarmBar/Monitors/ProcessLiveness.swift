import Foundation

/// Which working directories currently host a live process with the given
/// name. Tools whose state files carry no liveness record (OpenCode's db,
/// Kimi's session dirs) can only be waiting or working if their process is
/// actually running in the session's directory.
enum ProcessLiveness {
    nonisolated static func directories(processName: String) -> Set<String> {
        Set(directoryCounts(processName: processName).keys)
    }

    /// How many live processes with the given name run in each directory.
    /// Restart trails leave several sessions sharing one workDir; only as
    /// many of them can be live as there are processes there.
    nonisolated static func directoryCounts(processName: String) -> [String: Int] {
        counts(pgrepArgs: ["-x", processName])
    }

    /// For tools launched through interpreters (BearCode runs as
    /// `node .../main.mjs`), match the command line instead of the name.
    nonisolated static func directoryCounts(commandPattern: String) -> [String: Int] {
        counts(pgrepArgs: ["-f", commandPattern])
    }

    private nonisolated static func counts(pgrepArgs: [String]) -> [String: Int] {
        guard let pidText = run("/usr/bin/pgrep", pgrepArgs) else { return [:] }
        var counts: [String: Int] = [:]
        for line in pidText.split(separator: "\n") {
            guard let pid = Int(line.trimmingCharacters(in: .whitespaces)) else { continue }
            for path in cwds(pid: pid) { counts[path, default: 0] += 1 }
        }
        return counts
    }

    /// The pid of the newest live process with the given name whose cwd is
    /// the given directory. The session-to-process mapping for tools with
    /// no pid registry.
    nonisolated static func pid(processName: String, cwd: String) -> Int? {
        pid(pgrepArgs: ["-x", processName], cwd: cwd)
    }

    nonisolated static func pid(commandPattern: String, cwd: String) -> Int? {
        pid(pgrepArgs: ["-f", commandPattern], cwd: cwd)
    }

    private nonisolated static func pid(pgrepArgs: [String], cwd: String) -> Int? {
        guard let pidText = run("/usr/bin/pgrep", pgrepArgs) else { return nil }
        for line in pidText.split(separator: "\n").reversed() {
            guard let pid = Int(line.trimmingCharacters(in: .whitespaces)) else { continue }
            if cwds(pid: pid).contains(cwd) { return pid }
        }
        return nil
    }

    private nonisolated static func cwds(pid: Int) -> [String] {
        guard let output = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else {
            return []
        }
        return output.split(separator: "\n")
            .filter { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
