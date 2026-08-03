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
    nonisolated static let waitingAfter: TimeInterval = 30 * 60

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

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// active_sessions.json's entries may be bare id strings or objects with
    /// an id under one of a few likely keys; either way, gather everything
    /// that could plausibly be a session id.
    private nonisolated static func activeSessionIDs(root: URL) -> Set<String> {
        let path = root.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: path),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        let idKeys = ["id", "session_id", "sessionId", "sessionID"]
        var ids = Set<String>()
        for element in array {
            if let string = element as? String {
                ids.insert(string)
                continue
            }
            guard let entry = element as? [String: Any] else { continue }
            // Stale entries can outlive a crashed process; a dead pid means
            // the session is not actually live.
            if let pid = entry["pid"] as? Int, kill(pid_t(pid), 0) != 0 { continue }
            for key in idKeys {
                if let value = entry[key] as? String { ids.insert(value) }
            }
        }
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
            // A live process gets its real state from the update stream;
            // recency only decides for exited sessions.
            let tail = ClaudeCodeMonitor.tail(of: dir.appendingPathComponent("updates.jsonl"))
            status = tail.flatMap { GrokUpdatesParser.parse(tail: $0) }
                ?? .working(activity: "Working…")
        } else if age < waitingAfter {
            status = .waitingInput(prompt: lastAssistantPreview(dir: dir) ?? "")
        } else {
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

    /// chat_history.jsonl lines are {"type": system/user/assistant, ...}
    /// with message content whose exact shape wasn't pinned down, so this
    /// checks a few plausible spots for a string to preview.
    private nonisolated static func lastAssistantPreview(dir: URL) -> String? {
        let path = dir.appendingPathComponent("chat_history.jsonl")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (line["type"] as? String) == "assistant"
            else { continue }
            if let preview = textPreview(from: line) { return preview }
        }
        return nil
    }

    private nonisolated static func textPreview(from line: [String: Any]) -> String? {
        if let content = line["content"] as? String { return firstLine(content) }
        if let items = line["content"] as? [[String: Any]] {
            let text = items.compactMap { $0["text"] as? String }.joined(separator: " ")
            if !text.isEmpty { return firstLine(text) }
        }
        if let message = line["message"] as? [String: Any] {
            if let content = message["content"] as? String { return firstLine(content) }
            if let items = message["content"] as? [[String: Any]] {
                let text = items.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !text.isEmpty { return firstLine(text) }
            }
        }
        return nil
    }

    private nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 90 ? trimmed : String(trimmed.prefix(90)) + "…"
    }
}
