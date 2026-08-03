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

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let root = Self.defaultRoot()
                let sessions = await Task.detached {
                    Self.discover(
                        root: root,
                        liveCounts: ProcessLiveness.directoryCounts(processName: "kimi"),
                        now: now
                    )
                }.value
                store.sync(tool: .kimiCode, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    }

    /// BearCode is Zach's own fork of the kimi-code engine: identical state
    /// layout under ~/.bearcode, identical wire protocol and hooks, but it
    /// runs as `node .../bearcode-cli/.../main.mjs`, so liveness matches on
    /// the command line instead of a process name.
    struct BearCode: SessionMonitor {
        nonisolated static let commandPattern = "bearcode-cli/apps/kimi-code/dist/main.mjs"

        func start(into store: SessionStore) async {
            while !Task.isCancelled {
                if !store.isPaused {
                    let now = Date.now
                    let root = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".bearcode")
                    let sessions = await Task.detached {
                        KimiMonitor.discover(
                            root: root,
                            liveCounts: ProcessLiveness.directoryCounts(
                                commandPattern: Self.commandPattern),
                            now: now,
                            tool: .bearCode
                        )
                    }.value
                    store.sync(tool: .bearCode, sessions: sessions)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    nonisolated static func discover(
        root: URL,
        liveCounts: [String: Int]? = nil,
        now: Date,
        tool: AgentTool = .kimiCode
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
            let sessionDir = URL(fileURLWithPath: entry.sessionDir)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: sessionDir.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }

            let stateData = try? Data(contentsOf: sessionDir.appendingPathComponent("state.json"))
            let stateJSON = stateData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let stateWorkDir = stateJSON?["workDir"] as? String
            let stateUpdatedAt = (stateJSON?["updatedAt"] as? String).flatMap { ClaudeSessionParser.date($0) }

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
                lastActivityAt: lastActivity
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
                return demoted
            }
    }
}
