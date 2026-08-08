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

/// The Kimi family's hook list. UserPromptSubmit was added to mark the
/// start of a user turn, replacing a recency guess that was wrong in both
/// directions: a session thinking quietly read as idle, and a session that
/// had just finished read as working for another two minutes.
@MainActor
struct KimiHookEventsTests {
    private var names: [String] { TomlHooksTransform.events.map(\.name) }

    @Test func aUserTurnIsNowSignalled() {
        #expect(names.contains("UserPromptSubmit"))
    }

    /// The events that must keep working. UserPromptSubmit is additive and
    /// must not have displaced the approval path.
    @Test func theApprovalEventsSurvive() {
        for required in ["PermissionRequest", "PermissionResult", "PreToolUse", "Stop", "SessionEnd"] {
            #expect(names.contains(required), "\(required) was dropped")
        }
    }

    /// The whole reason UserPromptSubmit was chosen over TurnStarted. Any
    /// event name outside the legacy engine's 16 would make a build running
    /// KIMI_CODE_LEGACY_FLAG discard the entire hooks block, approvals
    /// included, because `hooks` is not an entry-keyed config section.
    @Test func everyEventExistsInBothEnginesEnums() {
        let legacySixteen: Set<String> = [
            "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
            "PermissionResult", "UserPromptSubmit", "Stop", "StopFailure", "Interrupt",
            "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop",
            "PreCompact", "PostCompact", "Notification",
        ]
        for name in names {
            #expect(legacySixteen.contains(name),
                    "\(name) is not in the legacy enum and would drop the whole hooks block")
        }
    }

    @Test func installWritesTheNewEvent() {
        let written = TomlHooksTransform.install("", scriptPath: "/tmp/hook.sh")
        #expect(written.contains("event = \"UserPromptSubmit\""))
        #expect(written.contains("event = \"PermissionRequest\""))
    }

    @Test func uninstallStillRemovesEverything() {
        let written = TomlHooksTransform.install("", scriptPath: "/tmp/hook.sh")
        let cleaned = TomlHooksTransform.uninstall(written)
        #expect(!cleaned.contains("UserPromptSubmit"))
        #expect(!TomlHooksTransform.isInstalled(cleaned))
    }
}
