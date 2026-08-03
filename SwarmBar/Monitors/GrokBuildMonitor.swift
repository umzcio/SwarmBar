import Foundation

/// Grok Build: ~/.grok/active_sessions.json is a JSON array that, when
/// non-empty, names the sessions currently running (entries may carry a
/// session id under a few different key spellings, and/or a pid; the exact
/// shape wasn't pinned down, so lookup is defensive). Per-session state
/// lives under ~/.grok/sessions/<url-encoded-cwd>/<uuid>/summary.json plus
/// chat_history.jsonl. session_search.sqlite and any other stray file next
/// to the per-cwd directories is skipped by only descending into actual
/// directories.
struct GrokBuildMonitor: SessionMonitor {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let root = Self.defaultRoot()
                let sessions = await Task.detached { Self.discover(root: root, now: now) }.value
                store.sync(tool: .grokBuild, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    nonisolated static func discover(root: URL, now: Date) -> [AgentSession] {
        let fm = FileManager.default
        let activeIds = activeSessionIDs(root: root)

        let sessionsRoot = root.appendingPathComponent("sessions")
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        var sessions: [AgentSession] = []
        for cwdDir in cwdDirs {
            guard isDirectory(cwdDir) else { continue }
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs {
                guard isDirectory(sessionDir),
                      let session = parseSession(dir: sessionDir, activeIds: activeIds, now: now)
                else { continue }
                sessions.append(session)
            }
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Returns the tool name awaiting permission if the session's trailing
    /// phase is permission_prompt, nil once the prompt has been answered
    /// (a later phase_changed supersedes it).
    nonisolated static func pendingPermissionTool(dir: URL) -> String? {
        guard let tail = ClaudeCodeMonitor.tail(of: dir.appendingPathComponent("events.jsonl"))
        else { return nil }
        var requestedTool: String?
        for raw in tail.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = line["type"] as? String
            else { continue }
            if type == "permission_requested", requestedTool == nil {
                requestedTool = line["tool_name"] as? String
            }
            if type == "phase_changed" {
                guard (line["phase"] as? String) == "permission_prompt" else { return nil }
                return requestedTool ?? "tool"
            }
        }
        return nil
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// active_sessions.json's entries may be bare id strings or objects with
    /// an id under one of a few likely keys. Two liveness corrections
    /// observed in the wild: entries can outlive a crashed process (dead
    /// pid), and the TUI can switch sessions within one process, leaving
    /// the abandoned session still registered under the same pid. Only the
    /// newest opened_at per pid is genuinely attached.
    nonisolated static func activeSessionIDs(root: URL) -> Set<String> {
        let path = root.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: path),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        let idKeys = ["id", "session_id", "sessionId", "sessionID"]

        var ids = Set<String>()
        var newestPerPid: [Int: (id: String, openedAt: Date)] = [:]
        for element in array {
            if let string = element as? String {
                ids.insert(string)
                continue
            }
            guard let entry = element as? [String: Any],
                  let id = idKeys.compactMap({ entry[$0] as? String }).first
            else { continue }
            guard let pid = entry["pid"] as? Int else {
                ids.insert(id)
                continue
            }
            guard kill(pid_t(pid), 0) == 0 else { continue }
            let openedAt = (entry["opened_at"] as? String)
                .flatMap { ClaudeSessionParser.date($0) } ?? .distantPast
            if let current = newestPerPid[pid], current.openedAt >= openedAt { continue }
            newestPerPid[pid] = (id, openedAt)
        }
        ids.formUnion(newestPerPid.values.map(\.id))
        return ids
    }

    private nonisolated static func parseSession(
        dir: URL, activeIds: Set<String>, now: Date
    ) -> AgentSession? {
        let summaryPath = dir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summaryPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let info = json["info"] as? [String: Any]
        let infoId = info?["id"] as? String
        let cwd = info?["cwd"] as? String

        guard let createdAt = (json["created_at"] as? String).flatMap(ClaudeSessionParser.date),
              let updatedAt = (json["updated_at"] as? String).flatMap(ClaudeSessionParser.date)
        else { return nil }

        let age = now.timeIntervalSince(updatedAt)
        guard age < discoveryWindow else { return nil }

        let isActive = infoId.map { activeIds.contains($0) } ?? false
        let status: SessionStatus
        if isActive {
            // events.jsonl records permission prompts explicitly
            // (phase_changed to permission_prompt + permission_requested);
            // otherwise the update stream carries the working state.
            let tail = ClaudeCodeMonitor.tail(of: dir.appendingPathComponent("updates.jsonl"))
            if let tool = pendingPermissionTool(dir: dir) {
                let command = tail.flatMap { GrokUpdatesParser.pendingToolCommand(tail: $0) }
                status = .waitingApproval(command: command ?? tool)
            } else {
                status = tail.flatMap { GrokUpdatesParser.parse(tail: $0) }
                    ?? .working(activity: "Working…")
            }
        } else {
            // No process means nothing to wait for; exited sessions are
            // idle no matter how fresh their last activity is.
            status = .idle
        }

        let id = infoId.flatMap { UUID(uuidString: $0) } ?? StableID.uuid(for: dir.lastPathComponent)
        let projectPath = cwd.map { URL(fileURLWithPath: $0) }

        return AgentSession(
            id: id,
            tool: .grokBuild,
            projectName: projectPath?.lastPathComponent ?? dir.lastPathComponent,
            projectPath: projectPath,
            status: status,
            startedAt: createdAt,
            lastActivityAt: updatedAt
        )
    }

}
