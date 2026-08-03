import Foundation

/// Codex CLI: sessions live at ~/.codex/sessions/YYYY/MM/DD/
/// rollout-<timestamp>-<uuid>.jsonl. The first line (session_meta) carries
/// cwd and session id; event_msg / response_item lines carry activity.
struct CodexMonitor: SessionMonitor {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let sessions = await Task.detached { Self.discover(now: now) }.value
                store.sync(tool: .codex, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func discover(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
        ) else { return [] }

        var sessions: [AgentSession] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl",
                  file.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .creationDateKey]),
                  let mtime = values.contentModificationDate,
                  now.timeIntervalSince(mtime) < discoveryWindow,
                  let tail = ClaudeCodeMonitor.tail(of: file),
                  let status = CodexSessionParser.parse(tail: tail, now: now)
            else { continue }

            let head = headText(of: file)
            let meta = CodexSessionParser.meta(head: head)
            let id = meta.sessionId.flatMap(UUID.init(uuidString:))
                ?? fallbackId(for: file.lastPathComponent)
            let projectPath = meta.cwd.map { URL(fileURLWithPath: $0) }
            sessions.append(AgentSession(
                id: id,
                tool: .codex,
                projectName: projectPath?.lastPathComponent ?? "codex session",
                projectPath: projectPath,
                status: status,
                startedAt: values.creationDate ?? mtime,
                lastActivityAt: mtime
            ))
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    private nonisolated static func headText(of file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// rollout-<timestamp>-<uuid>.jsonl: the trailing 36 characters of the
    /// stem are the uuid.
    private nonisolated static func fallbackId(for filename: String) -> UUID {
        let stem = filename.replacingOccurrences(of: ".jsonl", with: "")
        if stem.count >= 36, let id = UUID(uuidString: String(stem.suffix(36))) {
            return id
        }
        return UUID()
    }
}
