import Foundation

/// Claude Code: discovers sessions as ~/.claude*/projects/<escaped-cwd>/
/// <session-uuid>.jsonl (profiles share one store via symlink; roots are
/// deduped by resolved path) and polls the tail of each recent file.
/// Read-only; polling every few seconds is the phase 3 baseline, with
/// FSEventStream and hook integration as later sharpening.
struct ClaudeCodeMonitor: SessionMonitor {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60
    nonisolated static let tailBytes = 64 * 1024
    /// Ceiling for the growing tail read. A single record larger than this is
    /// pathological; giving up keeps a runaway file from being read whole on
    /// every poll.
    nonisolated static let maxTailBytes = 4 * 1024 * 1024

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let sessions = await Task.detached { Self.discover(now: now) }.value
                store.sync(tool: .claudeCode, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    nonisolated static func roots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let entries = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        var roots: [URL] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(".claude") {
            let projects = entry.appendingPathComponent("projects").resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: projects.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(projects.path).inserted
            else { continue }
            roots.append(projects)
        }
        return roots
    }

    /// Caches only the raw tail text, never the parsed status: parse takes
    /// `now` and can downgrade a status to idle once it goes stale, so a
    /// cached parse would freeze that time-dependent verdict and the row
    /// would stop updating even though the file itself is fine. Re-parsing
    /// a cached tail is cheap; re-reading the file is the expensive part.
    private nonisolated static let tailCache = TailCache<String>()

    nonisolated static func discover(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        var sessions: [AgentSession] = []
        var seenPaths = Set<String>()
        let livePids = TerminalFocuser.claudePidsBySession()
        for root in roots() {
            let projectDirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for projectDir in projectDirs {
                let files = (try? fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
                )) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    guard let values = try? file.resourceValues(
                            forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]),
                          let mtime = values.contentModificationDate,
                          now.timeIntervalSince(mtime) < discoveryWindow,
                          let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
                    else { continue }
                    seenPaths.insert(file.path)
                    guard let cachedTail = tailCache.value(
                            for: file, size: values.fileSize ?? 0, modified: mtime,
                            compute: { tail(of: file) }),
                          let parsed = ClaudeSessionParser.parse(tail: cachedTail, now: now)
                    else { continue }
                    let cwd = parsed.cwd ?? ClaudeSessionParser.decodeProjectDir(projectDir.lastPathComponent)
                    let projectPath = cwd.map { URL(fileURLWithPath: $0) }
                    sessions.append(AgentSession(
                        id: id,
                        tool: .claudeCode,
                        projectName: projectPath?.lastPathComponent ?? projectDir.lastPathComponent,
                        projectPath: projectPath,
                        status: parsed.status,
                        startedAt: values.creationDate ?? mtime,
                        lastActivityAt: mtime,
                        processAlive: livePids[id.uuidString.lowercased()] != nil
                    ))
                }
            }
        }
        tailCache.retain(paths: seenPaths)
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// The trailing complete lines of a JSONL file. Starts at `tailBytes` and
    /// doubles until the window holds at least one full record, because a
    /// single record larger than the window would otherwise yield only a
    /// fragment and drop the session from discovery entirely. Reading from
    /// offset 0 always counts as complete.
    nonisolated static func tail(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var window = UInt64(tailBytes)
        while true {
            let offset = size > window ? size - window : 0
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd() else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            if offset == 0 { return text }
            // The window's first newline marks the end of the partial first
            // line, unless it is the file's own trailing newline, in which
            // case the whole window is occupied by one oversized record with
            // nothing complete after it, so this window doesn't hold a full
            // record yet and needs to grow.
            if let newline = text.firstIndex(of: "\n") {
                let remainder = text[text.index(after: newline)...]
                if !remainder.isEmpty {
                    return String(remainder)
                }
            }
            if window >= UInt64(maxTailBytes) { return nil }
            window = min(window * 2, UInt64(maxTailBytes))
        }
    }
}
