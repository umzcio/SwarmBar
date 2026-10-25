import Foundation

/// OpenCode: session state lives in SQLite at
/// ~/.local/share/opencode/opencode.db. All the parsing and querying lives
/// in OpenCodeReader (a pure, testable type); this struct just owns the
/// read-only poll loop and default database location.
struct OpenCodeMonitor: SessionMonitor {
    nonisolated static let processName = "opencode"

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let sessions = await Task.detached {
                    Self.discover(now: now, context: .local())
                }.value
                store.sync(tool: .openCode, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The database under the context's home and liveness from its process
    /// table. A pid is looked up only when the context asks for one, and
    /// only for a session the reader left live; see
    /// `DiscoveryContext.resolvesPids` for why the Mac does not.
    nonisolated static func discover(now: Date, context: DiscoveryContext) -> [AgentSession] {
        let sessions = OpenCodeReader.sessions(
            dbPath: defaultDBPath(home: context.home).path,
            liveDirectories: liveDirectories(processes: context.processes),
            now: now
        )
        guard context.resolvesPids else { return sessions }
        return sessions.map { session in
            guard session.processAlive, let cwd = session.projectPath?.path else { return session }
            var session = session
            session.pid = context.processes.pid(processNames: [processName], cwd: cwd)
                .map { pid_t($0) }
            return session
        }
    }

    nonisolated static func defaultDBPath(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// Cwds of running opencode processes. A single name through the
    /// multi-name count runs one pgrep plus an lsof per pid, exactly what
    /// the single-name count this replaced ran, and yields the same keys.
    nonisolated static func liveDirectories(
        processes: any ProcessFacts = LocalProcessFacts()
    ) -> Set<String> {
        Set(processes.directoryCounts(processNames: [processName]).keys)
    }
}
