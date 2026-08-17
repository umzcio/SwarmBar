import Foundation

/// One agent state file as the helper shipped it. The helper sends bytes
/// and never verdicts, so the tail is parsed here with the same parser the
/// local monitor uses and there is no second implementation to drift.
struct RemoteSessionRecord: Decodable, Sendable {
    let tool: String
    let path: String
    let root: String
    let projectDir: String
    let mtime: TimeInterval
    /// Protocol 2 and later. Optional so a host still running an older
    /// helper decodes rather than failing the whole snapshot, which would
    /// take every session on that host with it.
    let created: TimeInterval?
    let size: Int
    let tail: String

    enum CodingKeys: String, CodingKey {
        case tool, path, root, mtime, created, size, tail
        case projectDir = "project_dir"
    }
}

struct RemoteProcessRecord: Decodable, Sendable {
    let pid: Int
    let user: String
    let comm: String
    let cwd: String
}

struct RemoteSnapshot: Decodable, Sendable {
    let ok: Bool
    let protocolVersion: Int
    let hostname: String
    let system: String
    let now: TimeInterval
    let roots: [String]
    let sessions: [RemoteSessionRecord]
    let processes: [RemoteProcessRecord]
    /// True when `ps` itself failed on the remote. An empty process list
    /// is otherwise indistinguishable from "no agents running", and BSD
    /// `ps` rejecting a GNU flag produces exactly that empty list.
    let processesFailed: Bool
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case ok, hostname, system, now, roots, sessions, processes, warnings
        case protocolVersion = "protocol"
        case processesFailed = "processes_failed"
    }

    static func decode(_ data: Data) throws -> RemoteSnapshot {
        try JSONDecoder().decode(RemoteSnapshot.self, from: data)
    }

    /// Maps a snapshot to sessions. Identity is derived from host plus
    /// absolute path, because two hosts can legitimately hold the same
    /// session id if a home directory is copied between them.
    static func sessions(from snapshot: RemoteSnapshot, host: String, now: Date) -> [AgentSession] {
        let liveCwds: Set<String> = snapshot.processesFailed
            ? []
            : Set(snapshot.processes.filter { $0.comm == "claude" }.map(\.cwd).filter { !$0.isEmpty })

        var result: [AgentSession] = []
        for record in snapshot.sessions where record.tool == "claudeCode" {
            guard let parsed = ClaudeSessionParser.parse(tail: record.tail, now: now) else { continue }
            let cwd = parsed.cwd ?? ClaudeSessionParser.decodeProjectDir(record.projectDir)
            let projectPath = cwd.map { URL(fileURLWithPath: $0) }
            let modified = Date(timeIntervalSince1970: record.mtime)
            // startedAt is what AgentSession.elapsedAnchor reads while a
            // session is active, so anchoring it on mtime like
            // lastActivityAt made an actively working row show its time
            // since the last write, which is always seconds. The local
            // monitor uses the file's creation date for exactly this
            // reason. A helper too old to send one falls back to mtime,
            // which is the previous behaviour rather than a wrong date.
            //
            // `created` is st_birthtime where the remote has one (Darwin);
            // elsewhere (Linux before Python 3.12) the helper falls back to
            // st_ctime, which every write refreshes and so usually equals
            // mtime for a transcript being actively appended to. It is not
            // bounded by mtime, though: a metadata-only change (chmod,
            // chown, rename, a hardlink) bumps ctime without a write, so
            // `created > mtime` is reachable on that fallback. When it
            // happens, startedAt lands after lastActivityAt and the row's
            // elapsed time goes negative; ElapsedTimeText clamps at zero, so
            // the visible effect is a row reading "0s", not a negative
            // duration.
            let started = record.created.map { Date(timeIntervalSince1970: $0) } ?? modified
            result.append(AgentSession(
                id: StableID.uuid(for: "\(host):\(record.path)"),
                tool: .claudeCode,
                projectName: projectPath?.lastPathComponent ?? record.projectDir,
                projectPath: projectPath,
                status: parsed.status,
                startedAt: started,
                lastActivityAt: modified,
                processAlive: cwd.map { liveCwds.contains($0) } ?? false,
                host: host
            ))
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }
}
