import Foundation

/// One run of a file's bytes at its true offset. On the wire it is
/// `[offset, base64]`. The bytes are written back exactly where they came
/// from and never adjusted: a tail chunk deliberately starts one byte early
/// on the newline that ends the previous record, and it runs through the
/// file's true size, half-written last line included.
struct RemoteChunk: Sendable, Equatable {
    let offset: Int
    let data: Data
}

extension RemoteChunk: Decodable {
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let offset = try container.decode(Int.self)
        let encoded = try container.decode(String.self)
        // A bad offset or bad base64 fails the whole snapshot. Writing what
        // could be salvaged would leave the mirror holding bytes the helper
        // believes it shipped differently, and the next growth chunk would
        // land on top of them.
        guard offset >= 0 else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "negative chunk offset \(offset)")
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "chunk is not base64")
        }
        self.init(offset: offset, data: data)
    }
}

/// One agent state file in the manifest. A file with no chunks is
/// unchanged since the last snapshot on this stream, but it is still
/// listed, because the listing is what tells the mirror the file still
/// exists.
struct RemoteFileRecord: Sendable, Equatable {
    let path: String
    let size: Int
    let mtime: TimeInterval
    /// Birth time where the remote records one (Darwin), else nil. Linux's
    /// st_ctime is not offered in its place because every write refreshes
    /// it, so it is really the last write.
    let created: TimeInterval?
    /// Discard whatever the mirror holds for this path before writing.
    let reset: Bool
    let chunks: [RemoteChunk]
}

extension RemoteFileRecord: Decodable {
    enum CodingKeys: String, CodingKey {
        case path, size, mtime, created, reset, chunks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let size = try container.decode(Int.self, forKey: .size)
        // Rejected like a negative offset: the mirror truncates to `size`,
        // and there is no honest file of negative length to make.
        guard size >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .size, in: container, debugDescription: "negative file size \(size)")
        }
        self.init(
            path: try container.decode(String.self, forKey: .path),
            size: size,
            mtime: try container.decode(TimeInterval.self, forKey: .mtime),
            created: try container.decodeIfPresent(TimeInterval.self, forKey: .created),
            reset: try container.decode(Bool.self, forKey: .reset),
            chunks: try container.decode([RemoteChunk].self, forKey: .chunks))
    }
}

/// A directory the mirror must hold: every ancestor of a shipped file
/// between it and its home, and any directory a tool's monitor lists.
struct RemoteDirRecord: Decodable, Sendable, Equatable {
    let path: String
    let mtime: TimeInterval
    let created: TimeInterval?
}

/// A file the helper found but could not ship this time. It says nothing
/// about the session, so the mirror keeps whatever it already holds.
struct RemoteOmission: Decodable, Sendable, Equatable {
    let path: String
    let reason: String
}

/// A home the helper scanned, and the user who owns it.
struct RemoteHome: Decodable, Sendable, Equatable {
    let path: String
    let user: String
}

/// The tmux pane an agent runs in, which is how keystrokes reach it.
struct RemotePane: Codable, Sendable, Equatable {
    let socket: String
    let id: String
}

struct RemoteProcessRecord: Sendable, Equatable {
    let pid: Int
    let ppid: Int
    let user: String
    /// The resolved agent name, so a BearCode process reads `bearcode`
    /// rather than the `node` that ps reports.
    let comm: String
    let args: String
    let cwd: String
    /// Empty when the process has no controlling terminal.
    let tty: String
    let pane: RemotePane?
    let open: [String]
    /// True when the helper could not read this process's open files, so
    /// an empty `open` means unknown rather than none.
    let openFailed: Bool
    let screen: String?
}

extension RemoteProcessRecord: Decodable {
    enum CodingKeys: String, CodingKey {
        case pid, ppid, user, comm, args, cwd, tty, pane, open, screen
        case openFailed = "open_failed"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pid: try container.decode(Int.self, forKey: .pid),
            ppid: try container.decode(Int.self, forKey: .ppid),
            user: try container.decode(String.self, forKey: .user),
            comm: try container.decode(String.self, forKey: .comm),
            args: try container.decode(String.self, forKey: .args),
            cwd: try container.decode(String.self, forKey: .cwd),
            tty: try container.decode(String.self, forKey: .tty),
            pane: try container.decodeIfPresent(RemotePane.self, forKey: .pane),
            open: try container.decode([String].self, forKey: .open),
            // The helper only sends the key when the read failed.
            openFailed: try container.decodeIfPresent(Bool.self, forKey: .openFailed) ?? false,
            screen: try container.decodeIfPresent(String.self, forKey: .screen))
    }
}

/// Protocol 3. The helper ships bytes and never verdicts: the files land in
/// a RemoteMirror, and the same readers the local monitors use run against
/// it, so there is no second parser to drift.
struct RemoteSnapshot: Decodable, Sendable {
    let ok: Bool
    let protocolVersion: Int
    /// Fixed for the life of one helper process. A new value means the
    /// helper restarted and every chunk it sends is relative to nothing the
    /// mirror holds.
    let stream: String
    let hostname: String
    let system: String
    let now: TimeInterval
    let homes: [RemoteHome]
    let files: [RemoteFileRecord]
    let dirs: [RemoteDirRecord]
    let omitted: [RemoteOmission]
    let warnings: [String]
    let processes: [RemoteProcessRecord]
    /// True when `ps` itself failed on the remote. An empty process list
    /// is otherwise indistinguishable from "no agents running", and BSD
    /// `ps` rejecting a GNU flag produces exactly that empty list.
    let processesFailed: Bool

    enum CodingKeys: String, CodingKey {
        case ok, stream, hostname, system, now, homes, files, dirs, omitted, warnings, processes
        case protocolVersion = "protocol"
        case processesFailed = "processes_failed"
    }

    static func decode(_ data: Data) throws -> RemoteSnapshot {
        try JSONDecoder().decode(RemoteSnapshot.self, from: data)
    }
}
