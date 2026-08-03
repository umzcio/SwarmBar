import Foundation

/// Kimi Code: ~/.kimi-code/session_index.jsonl maps sessionId -> sessionDir
/// -> workDir (last line wins on duplicate sessionId, since the index can
/// accumulate repeat entries). Each sessionDir has state.json (workDir,
/// updatedAt as an ISO string) and agents/main/wire.jsonl (protocol events
/// with epoch-millisecond timestamps). Sessions sampled on this machine were
/// empty shells whose wire.jsonl only carried metadata / config.update /
/// tools.set_active_tools, so there's no reliable "waiting on you" signal to
/// parse out of the wire protocol yet. Status here is honestly just
/// recency-based: recently touched sessions are treated as working, older
/// ones (up to the discovery window) as idle.
struct KimiMonitor: SessionMonitor {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60
    nonisolated static let activeAfter: TimeInterval = 2 * 60

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let root = Self.defaultRoot()
                let sessions = await Task.detached { Self.discover(root: root, now: now) }.value
                store.sync(tool: .kimiCode, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    }

    nonisolated static func discover(root: URL, now: Date) -> [AgentSession] {
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
            let status: SessionStatus = age < activeAfter
                ? .working(activity: "Working…")
                : .idle

            sessions.append(AgentSession(
                id: StableID.uuid(for: sessionId),
                tool: .kimiCode,
                projectName: projectPath?.lastPathComponent ?? sessionDir.lastPathComponent,
                projectPath: projectPath,
                status: status,
                startedAt: startedAt,
                lastActivityAt: lastActivity
            ))
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }
}
