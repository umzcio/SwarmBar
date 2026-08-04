import Foundation

/// Codex CLI: sessions live at ~/.codex/sessions/YYYY/MM/DD/
/// rollout-<timestamp>-<uuid>.jsonl. The first line (session_meta) carries
/// cwd and session id; event_msg / response_item lines carry activity.
struct CodexMonitor: SessionMonitor {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60

    /// Read once, computed once per file version; see CachedMeta below for
    /// why this one is safe to cache in full.
    private struct CachedMeta: Sendable {
        let cwd: String?
        let sessionId: String?
    }

    /// Caches only the raw tail text, never the parsed SessionStatus:
    /// CodexSessionParser.parse takes `now` and downgrades to idle once a
    /// line goes stale (staleAfter), so a cached parse would freeze that
    /// time-dependent verdict. Re-parsing a cached tail is cheap.
    private nonisolated static let tailCache = TailCache<String>()

    /// The 16 KB head only carries session_meta (cwd, session id), a pure
    /// function of the file's bytes with no time dependency, so the parsed
    /// meta itself is safe to cache in full, unlike the tail's status.
    private nonisolated static let headCache = TailCache<CachedMeta>()

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
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        ) else { return [] }

        var sessions: [AgentSession] = []
        var seenPaths = Set<String>()
        let livePids = TerminalFocuser.codexPidsBySessionSuffix()
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl",
                  file.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate,
                  now.timeIntervalSince(mtime) < discoveryWindow
            else { continue }
            let size = values.fileSize ?? 0
            seenPaths.insert(file.path)

            guard let cachedTail = tailCache.value(
                    for: file, size: size, modified: mtime,
                    compute: { ClaudeCodeMonitor.tail(of: file) }),
                  let status = CodexSessionParser.parse(tail: cachedTail, now: now)
            else { continue }

            let meta = headCache.value(
                for: file, size: size, modified: mtime,
                compute: {
                    let raw = CodexSessionParser.meta(head: headText(of: file))
                    return CachedMeta(cwd: raw.cwd, sessionId: raw.sessionId)
                }
            ) ?? CachedMeta(cwd: nil, sessionId: nil)
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
                lastActivityAt: mtime,
                processAlive: livePids["\(id.uuidString.lowercased()).jsonl"] != nil
            ))
        }
        tailCache.retain(paths: seenPaths)
        headCache.retain(paths: seenPaths)
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
