import Foundation

/// Kimi Code: ~/.kimi-code/session_index.jsonl maps sessionId -> sessionDir
/// -> workDir (last line wins on duplicate sessionId, since the index can
/// accumulate repeat entries). Each sessionDir has state.json (workDir,
/// updatedAt as an ISO string) and agents/main/wire.jsonl, whose trailing
/// events map to status via KimiWireParser. The wire flushes per settled
/// step (pending approval prompts never reach it in realtime), so the
/// recency heuristic remains the fallback when the parser finds nothing.
struct KimiMonitor: SessionMonitor {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60
    nonisolated static let activeAfter: TimeInterval = 2 * 60
    nonisolated static let staleAfter: TimeInterval = 30 * 60

    /// Kimi Code's process name, old and new. 2.0.0 runs as `kimi-code`;
    /// earlier builds ran as `kimi`. Matching only the old name made every
    /// live 2.0 session read as closed, and left Approve unable to find the
    /// terminal to read its selector.
    nonisolated static let processNames = ["kimi", "kimi-code"]

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let sessions = await Task.detached {
                    Self.discover(now: now, context: .local())
                }.value
                store.sync(tool: .kimiCode, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func defaultRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".kimi-code")
    }

    /// BearCode is a fork of the kimi-code engine: identical state layout
    /// under ~/.bearcode, identical wire protocol and hooks.
    ///
    /// Liveness has to match two shapes. From 0.34.0 it sets
    /// `process.title`, so it appears as a bare `bearcode` like Kimi does.
    /// Before that it ran as `node .../bearcode-cli/.../main.mjs` and only
    /// the command line identified it. Matching just one of these silently
    /// breaks the other: when the rename landed, every BearCode session
    /// read as dead and Approve fell through to opening a blank terminal.
    struct BearCode: SessionMonitor {
        nonisolated static let processName = "bearcode"
        nonisolated static let commandPattern = "bearcode-cli/apps/kimi-code/dist/main.mjs"

        func start(into store: SessionStore) async {
            while !Task.isCancelled {
                if !store.isPaused {
                    let now = Date.now
                    let sessions = await Task.detached {
                        KimiMonitor.discover(now: now, context: .local(), tool: .bearCode)
                    }.value
                    store.sync(tool: .bearCode, sessions: sessions)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }

        nonisolated static func defaultRoot(
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> URL {
            home.appendingPathComponent(".bearcode")
        }
    }

    /// Discovery for either member of the family against a context: its
    /// root under the context's home, liveness from the context's process
    /// table matched the way that member's process names itself, and
    /// sessionDir paths translated through `locate`.
    ///
    /// A pid is looked up only when the context asks for one, and only for
    /// a session still live after the per-directory cap. See
    /// `DiscoveryContext.resolvesPids` for why the Mac does not.
    nonisolated static func discover(
        now: Date, context: DiscoveryContext, tool: AgentTool = .kimiCode
    ) -> [AgentSession] {
        let isBearCode = tool == .bearCode
        let root = isBearCode
            ? BearCode.defaultRoot(home: context.home)
            : defaultRoot(home: context.home)
        let liveCounts = isBearCode
            ? context.processes.directoryCounts(
                processName: BearCode.processName, orCommandPattern: BearCode.commandPattern)
            : context.processes.directoryCounts(processNames: processNames)
        let sessions = discover(
            root: root, liveCounts: liveCounts, now: now, tool: tool, locate: context.locate)
        guard context.resolvesPids else { return sessions }
        let names = isBearCode ? [BearCode.processName] : processNames
        return sessions.map { session in
            guard session.processAlive, let cwd = session.projectPath?.path else { return session }
            var session = session
            session.pid = context.processes.pid(processNames: names, cwd: cwd).map { pid_t($0) }
            return session
        }
    }

    /// The working directory from state.json.
    ///
    /// The 0.34.0 engine renamed this key from `workDir` to `cwd`. Both are
    /// read because a state directory outlives an upgrade: files written by
    /// the old engine sit beside files written by the new one.
    nonisolated static func stateWorkDir(_ json: [String: Any]?) -> String? {
        (json?["workDir"] as? String) ?? (json?["cwd"] as? String)
    }

    /// The last-updated stamp from state.json.
    ///
    /// Also changed in 0.34.0, from an ISO 8601 string to a number. The
    /// number is epoch milliseconds, so it is scaled by magnitude rather
    /// than assumed: a seconds value for any plausible date is far below
    /// the threshold, and reading milliseconds as seconds would place the
    /// session tens of thousands of years in the future and hide it behind
    /// the discovery window forever.
    ///
    /// Returning nil here is not harmless. `discover` skips a session whose
    /// activity cannot be dated at all, so before this parsed, a session
    /// new enough to have no wire log yet would not appear.
    nonisolated static func stateUpdatedAt(_ json: [String: Any]?) -> Date? {
        if let text = json?["updatedAt"] as? String {
            return ClaudeSessionParser.date(text)
        }
        guard let number = json?["updatedAt"] as? Double, number > 0 else { return nil }
        let seconds = number > 1_000_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    nonisolated static func discover(
        root: URL,
        liveCounts: [String: Int]? = nil,
        now: Date,
        tool: AgentTool = .kimiCode,
        locate: (String) -> URL = { URL(fileURLWithPath: $0) }
    ) -> [AgentSession] {
        let fm = FileManager.default
        let indexFile = root.appendingPathComponent("session_index.jsonl")
        guard let text = try? String(contentsOf: indexFile, encoding: .utf8) else { return [] }

        // Preserve first-seen order but let a later line for the same
        // sessionId overwrite the earlier one's sessionDir/workDir.
        var entries: [String: (sessionDir: String, workDir: String?)] = [:]
        var order: [String] = []
        for raw in text.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionId = line["sessionId"] as? String,
                  let sessionDir = line["sessionDir"] as? String
            else { continue }
            if entries[sessionId] == nil { order.append(sessionId) }
            entries[sessionId] = (sessionDir, line["workDir"] as? String)
        }

        var sessions: [AgentSession] = []
        for sessionId in order {
            guard let entry = entries[sessionId] else { continue }
            // The index stores an absolute path as the tool wrote it, which
            // for a remote host names a directory on that host, not here.
            let sessionDir = locate(entry.sessionDir)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: sessionDir.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }

            let stateData = try? Data(contentsOf: sessionDir.appendingPathComponent("state.json"))
            let stateJSON = stateData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let stateWorkDir = Self.stateWorkDir(stateJSON)
            let stateUpdatedAt = Self.stateUpdatedAt(stateJSON)

            let wirePath = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
            let wireValues = try? wirePath.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey])

            // lastActivity is the newer of state.json's updatedAt and the
            // wire log's mtime; whichever file was touched most recently.
            let candidates = [stateUpdatedAt, wireValues?.contentModificationDate].compactMap { $0 }
            guard let lastActivity = candidates.max() else { continue }
            let age = now.timeIntervalSince(lastActivity)
            guard age < discoveryWindow else { continue }

            let sessionDirValues = try? sessionDir.resourceValues(forKeys: [.creationDateKey])
            let startedAt = sessionDirValues?.creationDate ?? wireValues?.creationDate ?? lastActivity

            let workDir = stateWorkDir ?? entry.workDir
            let projectPath = workDir.map { URL(fileURLWithPath: $0) }
            let live = liveCounts.map { counts in
                workDir.map { (counts[$0] ?? 0) > 0 } ?? false
            } ?? true
            let fallback: SessionStatus = live && age < activeAfter
                ? .working(activity: "Working…")
                : .idle
            let parsed = live && age < staleAfter
                ? ClaudeCodeMonitor.tail(of: wirePath).flatMap(KimiWireParser.parse(tail:))
                : nil
            let status = parsed ?? fallback

            sessions.append(AgentSession(
                id: StableID.uuid(for: sessionId),
                tool: tool,
                projectName: projectPath?.lastPathComponent ?? sessionDir.lastPathComponent,
                projectPath: projectPath,
                status: status,
                startedAt: startedAt,
                lastActivityAt: lastActivity,
                processAlive: live
            ))
        }
        if let liveCounts { sessions = capLive(sessions, counts: liveCounts) }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Sessions share workDirs across restarts, and a killed session's
    /// wire still parses as working for a while. Only as many sessions per
    /// directory can be non-idle as there are kimi processes running
    /// there; the newest win.
    private nonisolated static func capLive(
        _ sessions: [AgentSession],
        counts: [String: Int]
    ) -> [AgentSession] {
        var remaining = counts
        return sessions
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .map { session in
                guard session.status != .idle,
                      let directory = session.projectPath?.path
                else { return session }
                if remaining[directory, default: 0] > 0 {
                    remaining[directory]! -= 1
                    return session
                }
                var demoted = session
                demoted.status = .idle
                demoted.processAlive = false
                return demoted
            }
    }
}
