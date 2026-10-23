import Foundation
import Synchronization

enum RemoteMirrorError: Error, CustomStringConvertible {
    case cannotCreate(String)

    var description: String {
        switch self {
        case .cannotCreate(let path): "cannot create mirror file \(path)"
        }
    }
}

/// A sparse local copy of one host's agent state. Each remote path lives at
/// the same path beneath `root`, and each chunk the helper ships is written
/// at its true offset, so a 10 MB transcript of which only the last 64 KB
/// was shipped is a 10 MB file that is a hole up to its tail. The local
/// monitors' readers seek from the end or read from the start, never
/// through the middle, so they run against this tree unchanged and there is
/// no second parser for remote sessions.
///
/// Nothing here interprets agent state. Bytes land exactly where the helper
/// says they belong; correcting a chunk would break the next growth chunk,
/// which the helper computes against what it believes was shipped.
struct RemoteMirror: Sendable {
    let root: URL
    /// Whether a refused F_PUNCHHOLE has been logged yet. Shared by every
    /// copy of this mirror, so a volume that refuses every punch is
    /// reported once rather than on every write of every poll.
    private let punchFailureLogged = PunchFailureFlag()

    /// A file whose mirror occupies more than this is trimmed. Growth chunks
    /// append for as long as a session runs, and without a bound one long
    /// session would grow its mirror to the size of the real transcript,
    /// which is the copy this design exists to avoid.
    static let trimThresholdBytes = 8 * 1024 * 1024
    /// What trimming keeps from the end: the widest tail any local reader
    /// takes, so every reader sees the same lines after a trim as before.
    static let trimKeepBytes = ClaudeCodeMonitor.maxTailBytes

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Where a host's mirror lives. Only computed here, never created: the
    /// directory appears on the first `apply`, so a user with no hosts
    /// configured never gets one.
    static func root(forHost id: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent("app.swarmbar.SwarmBar", isDirectory: true)
            .appendingPathComponent("remote", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The mirror path for a remote absolute path, or nil for anything that
    /// could land outside `root`. The paths come from a remote host and are
    /// not trusted: a `..` component would let `/root/../../etc/x` climb
    /// out of the mirror and into the Mac's own files.
    func local(_ remotePath: String) -> URL? {
        guard remotePath.hasPrefix("/"), !remotePath.contains("\0") else { return nil }
        let components = remotePath.split(separator: "/")
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        guard !components.isEmpty else { return root }
        return URL(fileURLWithPath: root.path + "/" + components.joined(separator: "/"))
    }

    /// The remote path a mirror file stands for, or nil when `local` is not
    /// inside `root`.
    func remote(_ local: URL) -> String? {
        if let path = Self.relative(local.standardizedFileURL.path, to: root.path) {
            return path
        }
        // A reader that resolved symlinks (/var against /private/var) still
        // names a file inside the mirror.
        return Self.relative(
            local.standardizedFileURL.resolvingSymlinksInPath().path,
            to: root.resolvingSymlinksInPath().path)
    }

    private static func relative(_ path: String, to base: String) -> String? {
        if path == base { return "/" }
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count))
    }

    /// Discards the whole mirror. The next snapshot from a fresh helper
    /// stream ships every file anew.
    func reset() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0 else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// Writes one snapshot into the mirror. Throwing leaves the mirror in an
    /// unknown state relative to what the helper believes it shipped, so the
    /// caller must reset it and start a fresh helper stream rather than
    /// carry on.
    ///
    /// Returns warnings for chunks that were skipped rather than written,
    /// so the caller can surface them beside the helper's own.
    @discardableResult
    func apply(_ snapshot: RemoteSnapshot) throws -> [String] {
        let fm = FileManager.default
        // 700 because the mirror holds other users' transcripts when the
        // helper runs as root, and Caches is otherwise readable by anything
        // running as this user with a looser umask.
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        // A path that does not map is skipped outright: not written, not
        // kept, and not counted toward anything. Nor is one that maps to the
        // root itself, which a record must never replace.
        func mapped(_ path: String) -> URL? {
            guard let url = local(path), url.path != root.path else { return nil }
            return url
        }
        let files = snapshot.files.compactMap { record in mapped(record.path).map { (record, $0) } }
        let dirs = snapshot.dirs.compactMap { record in mapped(record.path).map { (record, $0) } }
        let omitted = Set(snapshot.omitted.compactMap { mapped($0.path)?.path })
        var warnings: [String] = []

        var keep = Set<String>()
        for path in files.map(\.1.path) + dirs.map(\.1.path) + omitted {
            keep.insert(path)
            for ancestor in ancestors(of: path) { keep.insert(ancestor) }
        }

        // Sweep first. It also removes any symlink beneath a home, so the
        // writes below never pass through one.
        for home in snapshot.homes {
            // A home the helper could not list yielded no files, which is
            // "could not look" and not "nothing there".
            guard let local = mapped(home.path), !omitted.contains(local.path),
                  try clearLinks(to: local.path, including: false)
            else { continue }
            var info = stat()
            guard lstat(local.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                try sweep(local.path, keep: keep, omitted: omitted)
            } else {
                try fm.removeItem(atPath: local.path)
            }
        }

        for (_, url) in dirs {
            try createDirectory(url)
        }
        for (record, url) in files {
            warnings += try write(record, to: url)
        }
        // Last, because creating and removing entries above moves a
        // directory's mtime.
        for (record, url) in dirs {
            var attributes: [FileAttributeKey: Any] = [
                .modificationDate: Date(timeIntervalSince1970: record.mtime)
            ]
            if let created = record.created {
                attributes[.creationDate] = Date(timeIntervalSince1970: created)
            }
            try fm.setAttributes(attributes, ofItemAtPath: url.path)
        }
        return warnings
    }

    /// Every directory between `path` and `root`, both excluded.
    private func ancestors(of path: String) -> [String] {
        var found: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while current.hasPrefix(root.path + "/") {
            found.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        return found
    }

    /// Removes everything under `directory` that the snapshot no longer
    /// lists. Never follows a symlink: the mirror only ever writes regular
    /// files and directories, so a link is foreign and is removed as an
    /// entry, leaving its target alone. An omitted path keeps its whole
    /// subtree, because the helper could not look there this time and that
    /// is not the same as there being nothing to see.
    private func sweep(_ directory: String, keep: Set<String>, omitted: Set<String>) throws {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: directory)
        } catch {
            // Logged, not thrown: what cannot be listed cannot be swept, and
            // the writes that follow are still right.
            NSLog("SwarmBar: cannot list mirror directory \(directory): \(error)")
            return
        }
        for name in names {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK || !keep.contains(path) {
                try fm.removeItem(atPath: path)
            } else if type == S_IFDIR && !omitted.contains(path) {
                try sweep(path, keep: keep, omitted: omitted)
            }
        }
    }

    /// Creates a directory and any missing parents, once nothing on the
    /// way to it is a symlink.
    private func createDirectory(_ url: URL) throws {
        try clearLinks(to: url.path, including: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Removes any symlink between `root` and `path`, and `path` itself when
    /// `including`. lstat only declines to follow the LAST component, so a
    /// link standing in for an ancestor would carry a sweep or a write out
    /// of the mirror while every check on the final path passed. The mirror
    /// never makes a link, so whichever one is found is foreign; it goes as
    /// an entry and its target is never touched. Returns false when a
    /// component is something other than a directory, which `path` cannot
    /// sit beneath.
    @discardableResult
    private func clearLinks(to path: String, including: Bool) throws -> Bool {
        guard path.hasPrefix(root.path + "/") else { return false }
        var components = path.dropFirst(root.path.count + 1).split(separator: "/")
        if !including { components = components.dropLast() }
        var current = root.path
        for component in components {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0 else { return true }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFLNK:
                try FileManager.default.removeItem(atPath: current)
                return true
            default:
                return false
            }
        }
        return true
    }

    private func write(_ record: RemoteFileRecord, to url: URL) throws -> [String] {
        let fm = FileManager.default
        try createDirectory(url.deletingLastPathComponent())

        var info = stat()
        var present = lstat(url.path, &info) == 0
        if present && info.st_mode & S_IFMT != S_IFREG {
            // Writing through a symlink would land outside the mirror.
            try fm.removeItem(atPath: url.path)
            present = false
        }
        if !present {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw RemoteMirrorError.cannotCreate(record.path)
            }
        }

        var warnings: [String] = []
        let unchanged = present && !record.reset && record.chunks.isEmpty && Int(info.st_size) == record.size
        if !unchanged {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            if record.reset {
                try handle.truncate(atOffset: 0)
            }
            // Where the file ends as each chunk lands. A chunk past it
            // leaves a gap that should be a hole and, on APFS, is not. In
            // offset order, or a later chunk listed first would open a gap
            // over bytes an earlier one is about to write, and the punch
            // would erase them.
            var end = record.reset || !present ? 0 : UInt64(info.st_size)
            var gaps: [(UInt64, UInt64)] = []
            for chunk in record.chunks.sorted(by: { $0.offset < $1.offset }) {
                guard !chunk.offset.addingReportingOverflow(chunk.data.count).overflow else {
                    warnings.append("skipped a chunk of \(record.path) whose end overflows: "
                        + "offset \(chunk.offset), \(chunk.data.count) bytes")
                    continue
                }
                let offset = UInt64(chunk.offset)
                if offset > end { gaps.append((end, offset)) }
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: chunk.data)
                end = max(end, offset + UInt64(chunk.data.count))
            }
            // Extending leaves a hole, which reads back as zeros and costs
            // no disk.
            try handle.truncate(atOffset: UInt64(record.size))
            for (from, to) in gaps {
                punchHole(handle, from: from, to: min(to, UInt64(record.size)))
            }
            if !Self.isWhole(record) {
                try trimIfOversized(handle, size: record.size)
            }
        }

        // After the writes, which bump mtime.
        var attributes: [FileAttributeKey: Any] = [
            .modificationDate: Date(timeIntervalSince1970: record.mtime)
        ]
        if let created = record.created.map({ Date(timeIntervalSince1970: $0) }) ?? Self.headTimestamp(record) {
            attributes[.creationDate] = created
        }
        try fm.setAttributes(attributes, ofItemAtPath: url.path)
        return warnings
    }

    /// True when one chunk carries the whole file. That is the helper's
    /// "whole" mode (JSON indexes and sqlite databases, bounded by the
    /// helper's own ceiling), and keeping only the last 4 MB of a database
    /// would corrupt it rather than bound it.
    private static func isWhole(_ record: RemoteFileRecord) -> Bool {
        record.chunks.contains { $0.offset == 0 && $0.data.count >= record.size }
    }

    /// Rewrites an oversized file to hold only its last `trimKeepBytes`, at
    /// the same offsets, plus its first line. The tail is all a tail reader
    /// ever takes. The first line is kept too because the helper ships it
    /// once, on a fresh ship, and Codex's session_meta lives there: losing
    /// it to a trim would leave the row without a project for the rest of
    /// the connection.
    private func trimIfOversized(_ handle: FileHandle, size: Int) throws {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              Int(info.st_blocks) * 512 > Self.trimThresholdBytes,
              size > Self.trimKeepBytes
        else { return }

        let keepFrom = size - Self.trimKeepBytes
        try handle.seek(toOffset: 0)
        let window = try handle.read(upToCount: min(CodexMonitor.maxHeadBytes, keepFrom)) ?? Data()
        var head = Data()
        // A leading zero is a hole, never the start of a record.
        if window.first != 0, let newline = window.firstIndex(of: UInt8(ascii: "\n")) {
            head = window[...newline]
        }
        try handle.seek(toOffset: UInt64(keepFrom))
        let tail = try handle.readToEnd() ?? Data()

        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: head)
        try handle.seek(toOffset: UInt64(keepFrom))
        try handle.write(contentsOf: tail)
        try handle.truncate(atOffset: UInt64(size))
        punchHole(handle, from: UInt64(head.count), to: UInt64(keepFrom))
    }

    /// Deallocates a range the mirror never wrote. APFS zero-fills the gap
    /// whenever a write lands less than 16 MB past the last allocated
    /// block, measured on this Mac, so a 10 MB transcript shipped as a head
    /// and a tail would otherwise occupy all 10 MB and the mirror would be
    /// a full copy after all. F_PUNCHHOLE takes whole blocks, so the range
    /// is narrowed to them and the partial blocks at either edge stay as
    /// allocated zeros. Best effort: a volume that refuses it still holds
    /// the right bytes, only more of them, and the trim then fires sooner.
    private func punchHole(_ handle: FileHandle, from: UInt64, to: UInt64) {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return }
        let block = UInt64(max(info.st_blksize, 512))
        let start = (from + block - 1) / block * block
        let stop = to / block * block
        guard stop > start else { return }
        var hole = fpunchhole_t(
            fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(stop - start))
        if fcntl(handle.fileDescriptor, F_PUNCHHOLE, &hole) != 0 {
            let reason = String(cString: strerror(errno))
            if punchFailureLogged.claim() {
                NSLog("SwarmBar: mirror at \(root.path) cannot punch holes (\(reason)); files stay dense")
            }
        }
    }

    /// The first top-level `timestamp` among the complete lines of a chunk
    /// at offset zero. Linux reports no birth time, and the transcript's own
    /// records are the platform-neutral start. Not just the first line:
    /// most Claude transcripts open with a `last-prompt` record that has no
    /// timestamp, and the helper ships the head through the first line that
    /// does.
    private static func headTimestamp(_ record: RemoteFileRecord) -> Date? {
        guard let chunk = record.chunks.first(where: { $0.offset == 0 }),
              chunk.data.first == UInt8(ascii: "{")
        else { return nil }
        let window = chunk.data.prefix(CodexMonitor.maxHeadBytes)
        var start = window.startIndex
        while let newline = window[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if let line = (try? JSONSerialization.jsonObject(with: window[start..<newline])) as? [String: Any],
               let stamp = line["timestamp"] as? String,
               let date = ClaudeSessionParser.date(stamp) {
                return date
            }
            start = window.index(after: newline)
        }
        return nil
    }
}

/// A one-way flag that hands out a single `true`, however many copies of a
/// mirror and however many threads ask.
private final class PunchFailureFlag: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
