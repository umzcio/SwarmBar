import Foundation
import Testing
@testable import SwarmBar

// Every test builds its mirror under the system temp directory. The real
// cache root is only ever computed, never created, so no test leaves a
// directory in ~/Library/Caches behind.

@Suite("Remote mirror")
struct RemoteMirrorTests {
    private func makeMirror() -> RemoteMirror {
        RemoteMirror(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-\(UUID().uuidString)"))
    }

    private func file(
        _ path: String, size: Int, mtime: Double = 1_792_000_000, created: Double? = nil,
        reset: Bool = true, chunks: [(Int, String)]
    ) -> RemoteFileRecord {
        RemoteFileRecord(
            path: path, size: size, mtime: mtime, created: created, reset: reset,
            chunks: chunks.map { RemoteChunk(offset: $0.0, data: Data($0.1.utf8)) })
    }

    private func snapshot(
        homes: [String] = ["/home/u"], files: [RemoteFileRecord],
        dirs: [RemoteDirRecord] = [], omitted: [RemoteOmission] = []
    ) -> RemoteSnapshot {
        RemoteSnapshot(
            ok: true, protocolVersion: 3, stream: "s", hostname: "devbox", system: "Linux", now: 0,
            homes: homes.map { RemoteHome(path: $0, user: "u") }, files: files, dirs: dirs,
            omitted: omitted, warnings: [], processes: [], processesFailed: false)
    }

    private func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func allocated(_ url: URL) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return Int(info.st_blocks) * 512
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    // MARK: Chunks

    @Test("a chunk lands at its true offset in a sparse file, and tail(of:) reads its records")
    func chunkLandsAtTrueOffsetInSparseFile() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let first = #"{"n":1,"p":""# + String(repeating: "x", count: 76) + #""}"#
        let second = #"{"n":2}"#
        // The helper starts a tail chunk one byte early, on the newline that
        // ends the record before it. Without it the hole's zeros and the
        // first record would read as one partial line and be dropped.
        let body = "\n" + first + "\n" + second + "\n"
        #expect(body.utf8.count == 100)
        let path = "/home/u/.claude/projects/-home-u-demo/a.jsonl"
        try mirror.apply(snapshot(files: [file(path, size: 10_000_000, chunks: [(9_999_900, body)])]))

        let local = try #require(mirror.local(path))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int)
        #expect(size == 10_000_000)
        #expect(try allocated(local) < 1_000_000)
        #expect(ClaudeCodeMonitor.tail(of: local) == first + "\n" + second + "\n")
    }

    @Test("a head chunk at offset zero reads back as the Codex head")
    func headChunkIsReadableAsCodexHead() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let head = #"{"type":"session_meta","payload":{"cwd":"/home/u/demo","session_id":"synthetic-1"}}"#
        let tail = "\n" + #"{"type":"event_msg","payload":{"type":"agent_message","message":"Synthetic."}}"# + "\n"
        let size = 5_000_000
        let path = "/root/.codex/sessions/2026/10/22/rollout-x.jsonl"
        try mirror.apply(snapshot(homes: ["/root"], files: [
            file(path, size: size, chunks: [(0, head + "\n"), (size - tail.utf8.count, tail)])
        ]))

        let text = CodexMonitor.headText(of: try #require(mirror.local(path)))
        #expect(text.split(separator: "\n").first.map(String.init) == head)
        let meta = CodexSessionParser.meta(head: text)
        #expect(meta.cwd == "/home/u/demo")
        #expect(meta.sessionId == "synthetic-1")
    }

    @Test("a growth chunk appends after what the mirror already holds")
    func appendKeepsEarlierChunk() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.claude/projects/-home-u-demo/b.jsonl"
        // Past the 64 KB first window, since a file the helper could ship
        // from offset zero never has a hole in front of it.
        let first = "\n" + #"{"n":1}"# + "\n"
        let oldSize = 100_000 + first.utf8.count
        try mirror.apply(snapshot(files: [file(path, size: oldSize, chunks: [(100_000, first)])]))

        let second = #"{"n":2}"# + "\n"
        try mirror.apply(snapshot(files: [
            file(path, size: oldSize + second.utf8.count, reset: false, chunks: [(oldSize, second)])
        ]))

        let local = try #require(mirror.local(path))
        #expect(ClaudeCodeMonitor.tail(of: local) == #"{"n":1}"# + "\n" + #"{"n":2}"# + "\n")
    }

    @Test("reset discards the bytes the mirror held before")
    func resetDiscardsOldBytes() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.grok/sessions/a/b/events.jsonl"
        let old = String(repeating: #"{"old":true}"# + "\n", count: 100)
        try mirror.apply(snapshot(files: [file(path, size: old.utf8.count, chunks: [(0, old)])]))

        let fresh = "\n" + #"{"new":true}"# + "\n"
        let size = 2000
        try mirror.apply(snapshot(files: [
            file(path, size: size, reset: true, chunks: [(size - fresh.utf8.count, fresh)])
        ]))

        let data = try bytes(try #require(mirror.local(path)))
        #expect(data.count == size)
        #expect(data.prefix(size - fresh.utf8.count).allSatisfy { $0 == 0 })
        #expect(data.suffix(fresh.utf8.count) == Data(fresh.utf8))
    }

    @Test("a file is truncated to the manifest's size, never left longer")
    func chunkPastSizeIsTruncated() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.grok/active_sessions.json"
        try mirror.apply(snapshot(files: [file(path, size: 3, chunks: [(0, "abcdef")])]))
        #expect(try bytes(try #require(mirror.local(path))) == Data("abc".utf8))
    }

    @Test("on a small file a head overlapping the tail writes the same bytes, in either order")
    func overlappingHeadAndTailAgree() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let head = #"{"type":"last-prompt"}"# + "\n" + #"{"type":"user","timestamp":"2026-10-02T08:30:00.000Z"}"# + "\n"
        let content = head + #"{"n":3}"# + "\n" + #"{"half"#
        for order in [[(0, head), (0, content)], [(0, content), (0, head)]] {
            let path = "/home/u/.claude/projects/-home-u-a/small-\(UUID().uuidString).jsonl"
            try mirror.apply(snapshot(files: [file(path, size: content.utf8.count, chunks: order)]))
            #expect(try bytes(try #require(mirror.local(path))) == Data(content.utf8))
        }
    }

    @Test("chunks listed out of order never have a hole punched over them")
    func outOfOrderChunksKeepTheirBytes() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let head = #"{"type":"session_meta","payload":{"cwd":"/home/u/demo"}}"# + "\n"
        let tail = "\n" + #"{"n":2}"# + "\n"
        let size = 5_000_000
        let path = "/root/.codex/sessions/2026/10/22/rollout-order.jsonl"
        try mirror.apply(snapshot(homes: ["/root"], files: [
            file(path, size: size, chunks: [(size - tail.utf8.count, tail), (0, head)])
        ]))
        let data = try bytes(try #require(mirror.local(path)))
        #expect(data.prefix(head.utf8.count) == Data(head.utf8))
        #expect(data.suffix(tail.utf8.count) == Data(tail.utf8))
    }

    @Test("a chunk whose end overflows is skipped with a warning rather than trapping")
    func overflowingChunkIsSkipped() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.grok/active_sessions.json"
        let warnings = try mirror.apply(snapshot(files: [RemoteFileRecord(
            path: path, size: 2, mtime: 0, created: nil, reset: true,
            chunks: [RemoteChunk(offset: Int.max - 1, data: Data("xyz".utf8)), RemoteChunk(offset: 0, data: Data("{}".utf8))])]))
        #expect(warnings.count == 1)
        #expect(try bytes(try #require(mirror.local(path))) == Data("{}".utf8))
    }

    @Test("an unchanged file keeps its bytes")
    func unchangedFileKeepsBytes() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.kimi-code/session_index.jsonl"
        let line = #"{"sessionId":"s"}"# + "\n"
        try mirror.apply(snapshot(files: [file(path, size: line.utf8.count, chunks: [(0, line)])]))
        try mirror.apply(snapshot(files: [file(path, size: line.utf8.count, reset: false, chunks: [])]))
        #expect(try bytes(try #require(mirror.local(path))) == Data(line.utf8))
    }

    // MARK: Manifest

    @Test("a file missing from the manifest is deleted, along with its emptied dir")
    func fileMissingFromManifestIsDeleted() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let kept = "/home/u/.claude/projects/-home-u-a/kept.jsonl"
        let gone = "/home/u/.claude/projects/-home-u-b/gone.jsonl"
        try mirror.apply(snapshot(files: [
            file(kept, size: 2, chunks: [(0, "{}")]),
            file(gone, size: 2, chunks: [(0, "{}")]),
        ]))
        let goneURL = try #require(mirror.local(gone))
        #expect(exists(goneURL))

        try mirror.apply(snapshot(files: [file(kept, size: 2, reset: false, chunks: [])]))
        #expect(exists(try #require(mirror.local(kept))))
        #expect(!exists(goneURL))
        #expect(!exists(goneURL.deletingLastPathComponent()))
        #expect(exists(try #require(mirror.local("/home/u/.claude/projects"))))
    }

    @Test("an omitted file is kept, since omitting says nothing about the session")
    func omittedFileIsKept() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.claude/projects/-home-u-a/big.jsonl"
        let line = #"{"n":1}"# + "\n"
        try mirror.apply(snapshot(files: [file(path, size: line.utf8.count, chunks: [(0, line)])]))
        try mirror.apply(snapshot(files: [], omitted: [
            RemoteOmission(path: path, reason: "no complete record within 4194304 bytes")
        ]))
        #expect(try bytes(try #require(mirror.local(path))) == Data(line.utf8))
    }

    @Test("a home the helper could not list is not swept")
    func omittedHomeIsNotSwept() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.claude/projects/-home-u-a/kept.jsonl"
        try mirror.apply(snapshot(files: [file(path, size: 2, chunks: [(0, "{}")])]))
        // An unlistable home yields no files at all; that is "could not
        // look", and the mirror must not read it as "nothing there".
        try mirror.apply(snapshot(files: [], omitted: [RemoteOmission(path: "/home/u", reason: "cannot list: Permission denied")]))
        #expect(try bytes(try #require(mirror.local(path))) == Data("{}".utf8))
    }

    @Test("records naming the remote root itself are skipped, so the mirror root is never replaced")
    func rootRecordsAreSkipped() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        try mirror.apply(snapshot(
            files: [file("/", size: 2, chunks: [(0, "{}")]), file("///", size: 2, chunks: [(0, "{}")])],
            dirs: [RemoteDirRecord(path: "//", mtime: 0, created: nil)]))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: mirror.root.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: mirror.root.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test("a dir listed in dirs survives with no files in it")
    func listedDirSurvives() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let dir = "/home/u/.grok/sessions/a/b/subagents/child"
        try mirror.apply(snapshot(files: [], dirs: [RemoteDirRecord(path: dir, mtime: 1_792_000_000, created: nil)]))
        try mirror.apply(snapshot(files: [], dirs: [RemoteDirRecord(path: dir, mtime: 1_792_000_000, created: nil)]))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: try #require(mirror.local(dir)).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("the sweep removes a symlink as an entry and never touches its target")
    func sweepNeverFollowsSymlinks() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let precious = outside.appendingPathComponent("precious.txt")
        try Data("keep".utf8).write(to: precious)

        try mirror.apply(snapshot(files: [file("/home/u/.claude/x.json", size: 2, chunks: [(0, "{}")])]))
        let home = try #require(mirror.local("/home/u"))
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try mirror.apply(snapshot(files: [file("/home/u/.claude/x.json", size: 2, reset: false, chunks: [])]))
        #expect(!exists(link))
        #expect(try Data(contentsOf: precious) == Data("keep".utf8))
    }

    @Test("a symlink standing in for an ancestor is removed before any sweep or write passes through it")
    func ancestorSymlinkIsNeverFollowed() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-outside-\(UUID().uuidString)")
        let precious = outside.appendingPathComponent("u/precious.txt")
        try FileManager.default.createDirectory(
            at: precious.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createDirectory(at: mirror.root, withIntermediateDirectories: true)
        let link = try #require(mirror.local("/home"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let path = "/home/u/.claude/x.json"
        try mirror.apply(snapshot(files: [file(path, size: 2, chunks: [(0, "{}")])]))
        #expect(try Data(contentsOf: precious) == Data("keep".utf8))
        #expect(!exists(outside.appendingPathComponent("u/.claude")))
        var info = stat()
        #expect(lstat(link.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
        #expect(try bytes(try #require(mirror.local(path))) == Data("{}".utf8))
    }

    @Test("a symlink standing where a manifest file belongs is replaced, not written through")
    func manifestPathSymlinkIsReplaced() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-target-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let path = "/home/u/.grok/active_sessions.json"
        try mirror.apply(snapshot(files: [file(path, size: 2, chunks: [(0, "{}")])]))
        let local = try #require(mirror.local(path))
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: outside)

        try mirror.apply(snapshot(files: [file(path, size: 2, reset: true, chunks: [(0, "[]")])]))
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        #expect(try bytes(local) == Data("[]".utf8))
    }

    // MARK: Times

    @Test("mtime and creation date are set from the manifest")
    func mtimeAndCreationAreSet() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.claude/projects/-home-u-a/t.jsonl"
        try mirror.apply(snapshot(files: [
            file(path, size: 2, mtime: 1_700_000_500.25, created: 1_700_000_000.5, chunks: [(0, "{}")])
        ]))
        let attributes = try FileManager.default.attributesOfItem(atPath: try #require(mirror.local(path)).path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        let created = try #require(attributes[.creationDate] as? Date)
        #expect(abs(modified.timeIntervalSince1970 - 1_700_000_500.25) < 0.001)
        #expect(abs(created.timeIntervalSince1970 - 1_700_000_000.5) < 0.001)
    }

    @Test("with no creation time, the first record's timestamp stands in")
    func creationFallsBackToFirstRecordTimestamp() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let path = "/home/u/.claude/projects/-home-u-a/u.jsonl"
        let head = #"{"type":"user","timestamp":"2026-10-01T10:00:00.000Z"}"# + "\n"
        let tail = "\n" + #"{"type":"assistant","timestamp":"2026-10-01T11:00:00.000Z"}"# + "\n"
        let size = 300_000
        try mirror.apply(snapshot(files: [
            file(path, size: size, created: nil, chunks: [(0, head), (size - tail.utf8.count, tail)])
        ]))
        let attributes = try FileManager.default.attributesOfItem(atPath: try #require(mirror.local(path)).path)
        let created = try #require(attributes[.creationDate] as? Date)
        #expect(created == ClaudeSessionParser.date("2026-10-01T10:00:00.000Z"))
    }

    @Test("the creation fallback reads past a leading record with no timestamp")
    func creationFallbackSkipsLastPrompt() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        // The shape most real transcripts open with: a last-prompt record
        // that carries no timestamp, then the first record that does. The
        // helper ships the head through that second line.
        let path = "/home/u/.claude/projects/-home-u-a/w.jsonl"
        let head = #"{"type":"last-prompt","lastPrompt":"Synthetic."}"# + "\n"
            + #"{"type":"user","timestamp":"2026-10-02T08:30:00.000Z"}"# + "\n"
        let tail = "\n" + #"{"type":"assistant","timestamp":"2026-10-02T09:00:00.000Z"}"# + "\n"
        let size = 300_000
        try mirror.apply(snapshot(files: [
            file(path, size: size, created: nil, chunks: [(0, head), (size - tail.utf8.count, tail)])
        ]))
        let attributes = try FileManager.default.attributesOfItem(atPath: try #require(mirror.local(path)).path)
        #expect(attributes[.creationDate] as? Date == ClaudeSessionParser.date("2026-10-02T08:30:00.000Z"))
    }

    @Test("dirs take the times the manifest gives them")
    func dirTimesAreSet() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let dir = "/home/u/.claude/projects/-home-u-a"
        try mirror.apply(snapshot(
            files: [file(dir + "/v.jsonl", size: 2, chunks: [(0, "{}")])],
            dirs: [RemoteDirRecord(path: dir, mtime: 1_700_000_000, created: nil)]))
        let attributes = try FileManager.default.attributesOfItem(atPath: try #require(mirror.local(dir)).path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(modified.timeIntervalSince1970 - 1_700_000_000) < 0.001)
    }

    // MARK: Paths

    @Test("paths map both ways, and anything outside the root maps to nil")
    func pathsMapBothWays() throws {
        let mirror = makeMirror()
        let path = "/root/.claude/x"
        let local = try #require(mirror.local(path))
        #expect(local.path.hasPrefix(mirror.root.path + "/"))
        #expect(mirror.remote(local) == path)
        #expect(mirror.remote(URL(fileURLWithPath: "/etc/hosts")) == nil)
        #expect(mirror.remote(mirror.root.appendingPathComponent("../elsewhere")) == nil)
    }

    @Test("a path climbing out with .. is rejected and never written")
    func dotDotIsRejected() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        #expect(mirror.local("/root/../../etc/x") == nil)
        #expect(mirror.local("relative/x") == nil)

        let escape = "escape-\(UUID().uuidString)"
        let hostile = "/../\(escape)/x"
        let target = mirror.root.deletingLastPathComponent().appendingPathComponent(escape)
        try mirror.apply(snapshot(
            files: [file(hostile, size: 2, chunks: [(0, "{}")])],
            dirs: [RemoteDirRecord(path: "/../\(escape)", mtime: 0, created: nil)]))
        #expect(!exists(target))
    }

    @Test("the cache root lives under the app's Caches directory, one per host")
    func rootForHost() {
        let id = UUID()
        let root = RemoteMirror.root(forHost: id)
        #expect(root.path.hasSuffix("/Library/Caches/app.swarmbar.SwarmBar/remote/\(id.uuidString)"))
    }

    @Test("the mirror root is created private to the user")
    func rootIsPrivate() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        try mirror.apply(snapshot(files: []))
        let attributes = try FileManager.default.attributesOfItem(atPath: mirror.root.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test("reset removes everything the mirror holds")
    func resetRemovesTree() throws {
        let mirror = makeMirror()
        try mirror.apply(snapshot(files: [file("/home/u/.grok/active_sessions.json", size: 2, chunks: [(0, "{}")])]))
        try mirror.reset()
        #expect(!exists(mirror.root))
    }

    // MARK: Size

    @Test("a mirror file holding more than 8 MB keeps only its last 4 MB, at the same offsets")
    func oversizedMirrorFileIsTrimmed() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let line = String(repeating: "x", count: 99) + "\n"
        let half = Data(String(repeating: line, count: 50_000).utf8)
        let whole = half + half
        #expect(whole.count == 10_000_000)
        let path = "/home/u/.claude/projects/-home-u-a/huge.jsonl"
        // Growth is what makes a mirror big: a fresh ship and then appends.
        try mirror.apply(snapshot(files: [RemoteFileRecord(
            path: path, size: half.count, mtime: 1_792_000_000, created: nil, reset: true,
            chunks: [RemoteChunk(offset: 0, data: half)])]))
        try mirror.apply(snapshot(files: [RemoteFileRecord(
            path: path, size: whole.count, mtime: 1_792_000_001, created: nil, reset: false,
            chunks: [RemoteChunk(offset: half.count, data: half)])]))

        let local = try #require(mirror.local(path))
        let data = try bytes(local)
        let keep = RemoteMirror.trimKeepBytes
        #expect(data.count == whole.count)
        #expect(data.suffix(keep) == whole.suffix(keep))
        // The first line survives so a reader of the head (Codex's
        // session_meta, the creation fallback) still finds it.
        #expect(data.prefix(line.utf8.count) == Data(line.utf8))
        #expect(data[line.utf8.count..<(whole.count - keep)].allSatisfy { $0 == 0 })
        #expect(try allocated(local) <= RemoteMirror.trimThresholdBytes)

        let reference = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-ref-\(UUID().uuidString)")
        try whole.write(to: reference)
        defer { try? FileManager.default.removeItem(at: reference) }
        #expect(ClaudeCodeMonitor.tail(of: local) == ClaudeCodeMonitor.tail(of: reference))
    }

    @Test("a file shipped whole is never trimmed, since a cut database is a corrupt one")
    func wholeFileIsNotTrimmed() throws {
        let mirror = makeMirror()
        defer { try? mirror.reset() }
        let whole = Data((0..<9_000_000).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) })
        let path = "/home/u/.local/share/opencode/opencode.db"
        try mirror.apply(snapshot(files: [RemoteFileRecord(
            path: path, size: whole.count, mtime: 1_792_000_000, created: nil, reset: true,
            chunks: [RemoteChunk(offset: 0, data: whole)])]))
        #expect(try bytes(try #require(mirror.local(path))) == whole)
    }
}
