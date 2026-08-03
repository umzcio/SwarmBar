import Foundation

/// OpenCode: session state lives in SQLite at
/// ~/.local/share/opencode/opencode.db. All the parsing and querying lives
/// in OpenCodeReader (a pure, testable type); this struct just owns the
/// read-only poll loop and default database location.
struct OpenCodeMonitor: SessionMonitor {
    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let dbPath = Self.defaultDBPath().path
                let sessions = await Task.detached {
                    OpenCodeReader.sessions(
                        dbPath: dbPath,
                        liveDirectories: Self.liveDirectories(),
                        now: now
                    )
                }.value
                store.sync(tool: .openCode, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func defaultDBPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// Working directories of running opencode processes. The database has
    /// no liveness record, so a session can only be waiting or working if
    /// some opencode process is actually running in its directory.
    nonisolated static func liveDirectories() -> Set<String> {
        guard let pidText = run("/usr/bin/pgrep", ["-x", "opencode"]) else { return [] }
        var directories: Set<String> = []
        for line in pidText.split(separator: "\n") {
            guard let pid = Int(line.trimmingCharacters(in: .whitespaces)) else { continue }
            guard let output = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { continue }
            for entry in output.split(separator: "\n") where entry.hasPrefix("n") {
                directories.insert(String(entry.dropFirst()))
            }
        }
        return directories
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
