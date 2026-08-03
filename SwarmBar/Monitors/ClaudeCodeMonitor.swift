import Foundation

/// Claude Code: discovers sessions as ~/.claude*/projects/<escaped-cwd>/
/// <session-uuid>.jsonl (profiles share one store via symlink; roots are
/// deduped by resolved path) and polls the tail of each recent file.
/// Read-only; polling every few seconds is the phase 3 baseline, with
/// FSEventStream and hook integration as later sharpening.
struct ClaudeCodeMonitor: SessionMonitor {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60
    nonisolated static let tailBytes = 64 * 1024

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

    nonisolated static func discover(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        var sessions: [AgentSession] = []
        for root in roots() {
            let projectDirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for projectDir in projectDirs {
                let files = (try? fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
                )) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    guard let values = try? file.resourceValues(
                            forKeys: [.contentModificationDateKey, .creationDateKey]),
                          let mtime = values.contentModificationDate,
                          now.timeIntervalSince(mtime) < discoveryWindow,
                          let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                          let tail = tail(of: file),
                          let parsed = ClaudeSessionParser.parse(tail: tail, now: now)
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
                        processAlive: TerminalFocuser.claudePid(forSession: id) != nil
                    ))
                }
            }
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    nonisolated static func tail(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // A mid-file seek can land mid-line; drop the partial first line.
        if offset > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }
}
