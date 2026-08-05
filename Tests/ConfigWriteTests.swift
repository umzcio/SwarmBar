import Foundation
import Testing
@testable import SwarmBar

@MainActor
struct ConfigWriteTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func inode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return attrs[.systemFileNumber] as? Int ?? -1
    }

    @Test func hardlinkedConfigsAllSeeTheNewContent() throws {
        // Agent profiles sharing one config by hardlink. An atomic write
        // would rename a new inode over `a`, leaving `b` on the old content,
        // so a toggle would apply to one profile and silently miss the rest.
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.json")
        let b = dir.appendingPathComponent("b.json")
        try "{\"hooks\":\"original\"}".write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: a, to: b)
        let before = try inode(a)

        try IntegrationManager.writePreservingLinks("{\"hooks\":\"rewritten\"}", to: a)

        #expect(try String(contentsOf: a, encoding: .utf8).contains("rewritten"))
        #expect(try String(contentsOf: b, encoding: .utf8).contains("rewritten"))
        // The link survives: same inode, so the two paths are still one file.
        #expect(try inode(a) == before)
        #expect(try inode(b) == before)
    }

    @Test func ordinaryFilesStillGetAnAtomicWrite() throws {
        // Single link, so atomicity is kept and the inode may change. What
        // matters is the content, not which inode carries it.
        let dir = try tempDir()
        let file = dir.appendingPathComponent("solo.json")
        try "{\"a\":1}".write(to: file, atomically: true, encoding: .utf8)

        try IntegrationManager.writePreservingLinks("{\"a\":2}", to: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"a\":2}")
    }

    @Test func shrinkingContentDoesNotLeaveATail() throws {
        // In place writes truncate first; without that, a shorter config
        // would leave trailing bytes of the old one and stop parsing.
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.json")
        let b = dir.appendingPathComponent("b.json")
        try String(repeating: "x", count: 500).write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: a, to: b)

        try IntegrationManager.writePreservingLinks("{}", to: a)

        #expect(try String(contentsOf: a, encoding: .utf8) == "{}")
        #expect(try String(contentsOf: b, encoding: .utf8) == "{}")
    }

    @Test func writingToAMissingPathCreatesIt() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("new.json")
        try IntegrationManager.writePreservingLinks("{\"fresh\":true}", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("fresh"))
    }
}
