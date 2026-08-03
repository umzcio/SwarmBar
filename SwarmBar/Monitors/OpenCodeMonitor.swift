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

    nonisolated static func liveDirectories() -> Set<String> {
        ProcessLiveness.directories(processName: "opencode")
    }
}
