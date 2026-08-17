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
    let size: Int
    let tail: String

    enum CodingKeys: String, CodingKey {
        case tool, path, root, mtime, size, tail
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
            result.append(AgentSession(
                id: StableID.uuid(for: "\(host):\(record.path)"),
                tool: .claudeCode,
                projectName: projectPath?.lastPathComponent ?? record.projectDir,
                projectPath: projectPath,
                status: parsed.status,
                startedAt: modified,
                lastActivityAt: modified,
                processAlive: cwd.map { liveCwds.contains($0) } ?? false,
                host: host
            ))
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }
}
