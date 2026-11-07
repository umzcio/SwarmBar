import Foundation
import Testing
@testable import SwarmBar

// A remote host chooses the logical size of every file in its mirror, and a
// sparse file of tens of gigabytes costs it nothing to name. Every reader
// that would load such a file whole must read within a fixed bound instead.
// The large files here are sparse: a gigabyte of hole costs no disk.

@MainActor
struct BoundedReadTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let gigabyte: UInt64 = 1024 * 1024 * 1024

    /// A file whose logical size is `hole` bytes of nothing followed by
    /// `tail`, the way a mirror holds a file shipped as a tail.
    private func writeSparse(_ url: URL, hole: UInt64, tail: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: hole)
        try handle.write(contentsOf: Data(tail.utf8))
    }

    @Test func wholeReadReturnsAFileWithinTheLimit() throws {
        let file = try makeDir().appendingPathComponent("small.json")
        try Data("[1,2,3]".utf8).write(to: file)
        #expect(BoundedRead.data(of: file, limit: 7) == Data("[1,2,3]".utf8))
        #expect(BoundedRead.data(of: file, limit: 6) == nil)
    }

    @Test func wholeReadRefusesAnOversizedSparseFileWithoutLoadingIt() throws {
        let file = try makeDir().appendingPathComponent("huge.json")
        try writeSparse(file, hole: Self.gigabyte, tail: "[]")
        #expect(BoundedRead.data(of: file) == nil)
    }

    @Test func wholeReadOfAMissingFileIsNil() throws {
        #expect(BoundedRead.data(of: try makeDir().appendingPathComponent("absent.json")) == nil)
    }

    @Test func kimiDiscoveryReadsOnlyTheTailOfAHugeIndex() throws {
        let root = try makeDir()
        let sessionDir = root.appendingPathComponent("sessions/wd/session_tail")
        let wire = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
        try FileManager.default.createDirectory(
            at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"metadata\"}\n".utf8).write(to: wire)
        let line = "{\"sessionId\":\"session_tail\",\"sessionDir\":\"\(sessionDir.path)\",\"workDir\":\"/tmp/proj-tail\"}"
        try writeSparse(
            root.appendingPathComponent("session_index.jsonl"), hole: Self.gigabyte, tail: "\n" + line + "\n")

        let sessions = KimiMonitor.discover(root: root, now: .now)
        #expect(sessions.map(\.projectName) == ["proj-tail"])
    }

    @Test func originToolFindsAKimiIdAtTheTailOfAHugeIndex() throws {
        let home = try makeDir()
        let line = "{\"sessionId\":\"session_synthetic\",\"sessionDir\":\"/nowhere\"}"
        try writeSparse(
            home.appendingPathComponent(".kimi-code/session_index.jsonl"),
            hole: Self.gigabyte, tail: "\n" + line + "\n")
        #expect(HookServer.originTool(rawSessionID: "session_synthetic", home: home) == .kimiCode)
    }

    @Test func grokActiveSessionsOverTheLimitAreNotLoaded() throws {
        let root = try makeDir()
        let id = UUID().uuidString
        try writeSparse(
            root.appendingPathComponent("active_sessions.json"),
            hole: Self.gigabyte, tail: "[{\"id\":\"\(id)\"}]")
        #expect(GrokBuildMonitor.activeSessionIDs(root: root).isEmpty)
    }

    @Test func grokSummaryOverTheLimitIsSkipped() throws {
        let root = try makeDir()
        let iso = ISO8601DateFormatter().string(from: .now)
        func summary(_ id: String, _ cwd: String) -> String {
            "{\"info\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\"},\"created_at\":\"\(iso)\",\"updated_at\":\"\(iso)\"}"
        }
        let small = UUID().uuidString, huge = UUID().uuidString
        let smallPath = root.appendingPathComponent("sessions/cwd/\(small)/summary.json")
        try FileManager.default.createDirectory(
            at: smallPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(summary(small, "/tmp/proj-small").utf8).write(to: smallPath)
        try writeSparse(
            root.appendingPathComponent("sessions/cwd/\(huge)/summary.json"),
            hole: Self.gigabyte, tail: summary(huge, "/tmp/proj-huge"))
        #expect(GrokBuildMonitor.discover(root: root, now: .now).map(\.projectName) == ["proj-small"])
    }
}
