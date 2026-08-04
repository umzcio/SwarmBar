import Foundation
import SQLite3
import Testing
@testable import SwarmBar

// These monitors discover from arbitrary directories/databases (not bundled
// fixtures), so tests build small trees and databases under the system temp
// directory at runtime instead of shipping fixture directories as resources.

@MainActor
struct StableIDTests {
    @Test func sameInputProducesSameUUID() {
        #expect(StableID.uuid(for: "ses_abc123") == StableID.uuid(for: "ses_abc123"))
    }

    @Test func differentInputProducesDifferentUUID() {
        #expect(StableID.uuid(for: "ses_abc123") != StableID.uuid(for: "session_e8d7b197"))
    }
}

@MainActor
struct KimiMonitorTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes one session_index.jsonl entry plus its sessionDir with
    /// state.json (updatedAt) and an empty agents/main/wire.jsonl.
    @discardableResult
    private func writeSession(
        root: URL, sessionId: String, workDir: String, updatedAt: Date
    ) throws -> URL {
        let sessionDir = root.appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(
            at: sessionDir.appendingPathComponent("agents/main"), withIntermediateDirectories: true)

        let indexPath = root.appendingPathComponent("session_index.jsonl")
        let indexLine = "{\"sessionId\":\"\(sessionId)\",\"sessionDir\":\"\(sessionDir.path)\",\"workDir\":\"\(workDir)\"}\n"
        let existing = (try? String(contentsOf: indexPath, encoding: .utf8)) ?? ""
        try (existing + indexLine).write(to: indexPath, atomically: true, encoding: .utf8)

        let iso = ISO8601DateFormatter().string(from: updatedAt)
        let state = "{\"workDir\":\"\(workDir)\",\"updatedAt\":\"\(iso)\"}"
        try state.write(to: sessionDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let wirePath = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
        try "{\"type\":\"metadata\"}\n".write(to: wirePath, atomically: true, encoding: .utf8)
        // Discovery takes the newer of state.json's updatedAt and the wire
        // log's on-disk mtime; the file was just written, so back-date its
        // mtime to match the scenario instead of leaving it at "now".
        try FileManager.default.setAttributes(
            [.modificationDate: updatedAt], ofItemAtPath: wirePath.path)
        return sessionDir
    }

    @Test func freshSessionIsWorking() throws {
        let root = try makeRoot()
        let now = Date.now
        try writeSession(root: root, sessionId: "session_a", workDir: "/tmp/proj-a", updatedAt: now.addingTimeInterval(-5))
        let sessions = KimiMonitor.discover(root: root, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .working(activity: "Working…"))
        #expect(sessions.first?.projectName == "proj-a")
    }

    @Test func staleSessionIsIdle() throws {
        let root = try makeRoot()
        let now = Date.now
        try writeSession(
            root: root, sessionId: "session_b", workDir: "/tmp/proj-b",
            updatedAt: now.addingTimeInterval(-2 * 60 * 60))
        let sessions = KimiMonitor.discover(root: root, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .idle)
    }

    @Test func outOfWindowSessionIsExcluded() throws {
        let root = try makeRoot()
        let now = Date.now
        try writeSession(
            root: root, sessionId: "session_c", workDir: "/tmp/proj-c",
            updatedAt: now.addingTimeInterval(-9 * 60 * 60))
        let sessions = KimiMonitor.discover(root: root, now: now)
        #expect(sessions.isEmpty)
    }
}

@MainActor
struct OpenCodeReaderTests {
    private func makeDB() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let schema = """
        CREATE TABLE session(id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER);
        CREATE TABLE part(id TEXT, message_id TEXT, data TEXT);
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        return path
    }

    private func insert(dbPath: String, sql: String) {
        var db: OpaquePointer?
        sqlite3_open(dbPath, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }

    @Test func trailingStepStartIsWorking() throws {
        let path = try makeDB()
        let now = Date.now
        let updated = Int64((now.timeIntervalSince1970 * 1000).rounded())
        insert(dbPath: path, sql: """
        INSERT INTO session VALUES ('s1', '/tmp/proj-1', 'title', \(updated - 1000), \(updated));
        INSERT INTO message VALUES ('m1', 's1', \(updated));
        INSERT INTO part VALUES ('p1', 'm1', '{"type":"step-start"}');
        """)
        let sessions = OpenCodeReader.sessions(dbPath: path, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .working(activity: "Working…"))
        #expect(sessions.first?.projectName == "proj-1")
    }

    @Test func finishedTurnWithTextPartIsWaitingInput() throws {
        let path = try makeDB()
        let now = Date.now
        let updatedDate = now.addingTimeInterval(-5 * 60)
        let updated = Int64((updatedDate.timeIntervalSince1970 * 1000).rounded())
        insert(dbPath: path, sql: """
        INSERT INTO session VALUES ('s2', '/tmp/proj-2', 'title', \(updated - 1000), \(updated));
        INSERT INTO message VALUES ('m2', 's2', \(updated));
        INSERT INTO part VALUES ('p1', 'm2', '{"type":"text","text":"Done, want me to continue?"}');
        INSERT INTO part VALUES ('p2', 'm2', '{"type":"step-finish"}');
        """)
        let sessions = OpenCodeReader.sessions(dbPath: path, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .waitingInput(prompt: "Done, want me to continue?"))
    }

    @Test func oldSessionIsIdle() throws {
        let path = try makeDB()
        let now = Date.now
        let updatedDate = now.addingTimeInterval(-2 * 60 * 60)
        let updated = Int64((updatedDate.timeIntervalSince1970 * 1000).rounded())
        insert(dbPath: path, sql: """
        INSERT INTO session VALUES ('s3', '/tmp/proj-3', 'title', \(updated - 1000), \(updated));
        INSERT INTO message VALUES ('m3', 's3', \(updated));
        INSERT INTO part VALUES ('p1', 'm3', '{"type":"step-finish"}');
        """)
        let sessions = OpenCodeReader.sessions(dbPath: path, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .idle)
    }

    @Test func missingDatabaseYieldsNoSessions() {
        let sessions = OpenCodeReader.sessions(dbPath: "/nonexistent/opencode.db", now: .now)
        #expect(sessions.isEmpty)
    }

    @Test func supersededSessionsInSameDirectoryGoIdle() throws {
        let path = try makeDB()
        let now = Date.now
        let older = Int64(((now.timeIntervalSince1970 - 10 * 60) * 1000).rounded())
        let newer = Int64((now.timeIntervalSince1970 * 1000).rounded())
        insert(dbPath: path, sql: """
        INSERT INTO session VALUES ('ghost', '/tmp/proj-4', 'title', \(older - 1000), \(older));
        INSERT INTO message VALUES ('m4', 'ghost', \(older));
        INSERT INTO part VALUES ('p1', 'm4', '{"type":"text","text":"abandoned"}');
        INSERT INTO session VALUES ('live', '/tmp/proj-4', 'title', \(newer - 1000), \(newer));
        INSERT INTO message VALUES ('m5', 'live', \(newer));
        INSERT INTO part VALUES ('p2', 'm5', '{"type":"step-start"}');
        INSERT INTO session VALUES ('other', '/tmp/proj-5', 'title', \(older - 1000), \(older));
        INSERT INTO message VALUES ('m6', 'other', \(older));
        INSERT INTO part VALUES ('p3', 'm6', '{"type":"text","text":"different directory"}');
        """)
        let sessions = OpenCodeReader.sessions(dbPath: path, now: now)
        #expect(sessions.count == 3)
        let live = sessions.filter { $0.projectName == "proj-4" }
            .max(by: { $0.lastActivityAt < $1.lastActivityAt })
        #expect(live?.status == .working(activity: "Working…"))
        let ghost = sessions.filter { $0.projectName == "proj-4" }
            .min(by: { $0.lastActivityAt < $1.lastActivityAt })
        #expect(ghost?.status == .idle)
        let other = sessions.first(where: { $0.projectName == "proj-5" })
        #expect(other?.status == .done(summary: "different directory"))
    }

    @Test func sessionsOutsideLiveDirectoriesGoIdle() throws {
        let path = try makeDB()
        let now = Date.now
        let updated = Int64((now.timeIntervalSince1970 * 1000).rounded())
        insert(dbPath: path, sql: """
        INSERT INTO session VALUES ('live', '/tmp/proj-live', 'title', \(updated - 1000), \(updated));
        INSERT INTO message VALUES ('m1', 'live', \(updated));
        INSERT INTO part VALUES ('p1', 'm1', '{"type":"step-start"}');
        INSERT INTO session VALUES ('dead', '/tmp/proj-dead', 'title', \(updated - 1000), \(updated));
        INSERT INTO message VALUES ('m2', 'dead', \(updated));
        INSERT INTO part VALUES ('p2', 'm2', '{"type":"step-start"}');
        """)
        let sessions = OpenCodeReader.sessions(
            dbPath: path, liveDirectories: ["/tmp/proj-live"], now: now)
        #expect(sessions.first(where: { $0.projectName == "proj-live" })?.status
                == .working(activity: "Working…"))
        #expect(sessions.first(where: { $0.projectName == "proj-dead" })?.status == .idle)
    }
}

@MainActor
struct GrokBuildMonitorTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeSession(
        root: URL, id: String, cwd: String, updatedAt: Date, preview: String? = nil
    ) throws -> URL {
        let encodedCwd = cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "proj"
        let sessionDir = root.appendingPathComponent("sessions")
            .appendingPathComponent(encodedCwd).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        let summary: [String: Any] = [
            "info": ["id": id, "cwd": cwd],
            "created_at": iso.string(from: updatedAt),
            "updated_at": iso.string(from: updatedAt),
            "agent_name": "grok",
        ]
        let data = try JSONSerialization.data(withJSONObject: summary)
        try data.write(to: sessionDir.appendingPathComponent("summary.json"))

        if let preview {
            let line = "{\"type\":\"assistant\",\"content\":\"\(preview)\"}\n"
            try line.write(
                to: sessionDir.appendingPathComponent("chat_history.jsonl"),
                atomically: true, encoding: .utf8)
        }
        return sessionDir
    }

    private func writeActive(root: URL, ids: [String]) throws {
        let array = ids.map { ["id": $0] }
        let data = try JSONSerialization.data(withJSONObject: array)
        try data.write(to: root.appendingPathComponent("active_sessions.json"))
    }

    @Test func activeSessionIsWorking() throws {
        let root = try makeRoot()
        let id = UUID().uuidString
        let now = Date.now
        try writeSession(root: root, id: id, cwd: "/tmp/proj-active", updatedAt: now)
        try writeActive(root: root, ids: [id])

        let sessions = GrokBuildMonitor.discover(root: root, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .working(activity: "Working…"))
        #expect(sessions.first?.id == UUID(uuidString: id))
    }

    @Test func inactiveFreshSessionIsIdleNotWaiting() throws {
        let root = try makeRoot()
        let id = UUID().uuidString
        let now = Date.now
        try writeSession(
            root: root, id: id, cwd: "/tmp/proj-fresh", updatedAt: now.addingTimeInterval(-60),
            preview: "Ready for review, shall I proceed?")
        try writeActive(root: root, ids: [])

        let sessions = GrokBuildMonitor.discover(root: root, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .idle)
    }

    @Test func sessionSwitchInOneProcessKeepsOnlyNewestActive() throws {
        // The TUI can switch sessions within one process; the abandoned
        // session stays registered under the same pid and must not count
        // as live.
        let root = try makeRoot()
        let abandoned = UUID().uuidString
        let current = UUID().uuidString
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let iso = ISO8601DateFormatter()
        let entries: [[String: Any]] = [
            ["session_id": abandoned, "pid": pid,
             "opened_at": iso.string(from: Date(timeIntervalSinceNow: -120))],
            ["session_id": current, "pid": pid,
             "opened_at": iso.string(from: Date(timeIntervalSinceNow: -30))],
        ]
        let data = try JSONSerialization.data(withJSONObject: entries)
        try data.write(to: root.appendingPathComponent("active_sessions.json"))

        let active = GrokBuildMonitor.activeSessionIDs(root: root)
        #expect(active == [current])
    }

    @Test func staleInactiveSessionIsIdle() throws {
        let root = try makeRoot()
        let id = UUID().uuidString
        let now = Date.now
        try writeSession(
            root: root, id: id, cwd: "/tmp/proj-stale",
            updatedAt: now.addingTimeInterval(-2 * 60 * 60))
        try writeActive(root: root, ids: [])

        let sessions = GrokBuildMonitor.discover(root: root, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .idle)
    }
}

@MainActor
struct GrokUpdatesParserTests {
    private func envelope(_ update: String) -> String {
        "{\"method\":\"session/update\",\"params\":{\"update\":\(update)}}"
    }

    @Test func pendingQuestionIsWaitingWithPrompt() {
        let tail = [
            envelope("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Here you go:\"}}"),
            envelope("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"c1\",\"title\":\"ask_user_question\",\"rawInput\":{\"questions\":[{\"question\":\"Should I order 47 rubber ducks?\"}]}}"),
        ].joined(separator: "\n")
        #expect(GrokUpdatesParser.parse(tail: tail)
                == .waitingInput(prompt: "Should I order 47 rubber ducks?"))
    }

    @Test func trailingToolCallIsRunningTool() {
        let tail = envelope("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"c2\",\"title\":\"run_command\"}")
        #expect(GrokUpdatesParser.parse(tail: tail)
                == .runningTool(activity: "Running run_command"))
    }

    @Test func stopAfterPlainReportIsDone() {
        let tail = [
            envelope("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"All done, ready for review.\"}}"),
            envelope("{\"sessionUpdate\":\"hook_execution\",\"event_name\":\"stop\",\"runs\":[]}"),
        ].joined(separator: "\n")
        #expect(GrokUpdatesParser.parse(tail: tail)
                == .done(summary: "All done, ready for review."))
    }

    @Test func stopAfterQuestionIsWaiting() {
        let tail = [
            envelope("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Ship it, or keep polishing?\"}}"),
            envelope("{\"sessionUpdate\":\"hook_execution\",\"event_name\":\"stop\",\"runs\":[]}"),
        ].joined(separator: "\n")
        #expect(GrokUpdatesParser.parse(tail: tail)
                == .waitingInput(prompt: "Ship it, or keep polishing?"))
    }

    @Test func trailingThoughtIsWorking() {
        let tail = envelope("{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Hmm.\"}}")
        #expect(GrokUpdatesParser.parse(tail: tail) == .working(activity: "Thinking…"))
    }

    @Test func metadataOnlyIsNil() {
        let tail = "{\"method\":\"x\",\"params\":{\"update\":{\"other\":1}}}"
        #expect(GrokUpdatesParser.parse(tail: tail) == nil)
    }
}

@MainActor
struct GrokPermissionDetectionTests {
    @Test func pendingPromptDetectedFromEvents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let events = """
        {"ts":"t","type":"tool_started","tool_name":"run_terminal_command"}
        {"ts":"t","type":"phase_changed","phase":"permission_prompt"}
        {"ts":"t","type":"permission_requested","tool_name":"run_terminal_command"}
        """
        try events.write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        #expect(GrokBuildMonitor.pendingPermissionTool(dir: dir) == "run_terminal_command")
    }

    @Test func answeredPromptIsNotPending() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let events = """
        {"ts":"t","type":"phase_changed","phase":"permission_prompt"}
        {"ts":"t","type":"permission_requested","tool_name":"run_terminal_command"}
        {"ts":"t","type":"phase_changed","phase":"working"}
        """
        try events.write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        #expect(GrokBuildMonitor.pendingPermissionTool(dir: dir) == nil)
    }

    @Test func pendingToolCommandFromUpdates() {
        let tail = "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"title\":\"run_terminal_command\",\"rawInput\":{\"command\":\"rm -rf build/\"}}}}"
        #expect(GrokUpdatesParser.pendingToolCommand(tail: tail) == "rm -rf build/")
    }
}

@MainActor
struct ProjectPathValidationTests {
    @Test func acceptsAnExistingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(TerminalFocuser.isDirectory(dir.path))
    }

    @Test func rejectsARegularFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("payload.sh")
        try "#!/bin/bash\necho hi\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!TerminalFocuser.isDirectory(file.path))
    }

    @Test func rejectsAMissingPath() {
        #expect(!TerminalFocuser.isDirectory("/nope/does/not/exist"))
    }

    @Test func rejectsEmptyAndRelativeJunk() {
        #expect(!TerminalFocuser.isDirectory(""))
    }
}

@MainActor
struct TailWindowTests {
    private func writeFile(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").appending("\n").write(
            to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func readsSmallFilesWhole() throws {
        let file = try writeFile(["{\"a\":1}", "{\"a\":2}"])
        let tail = ClaudeCodeMonitor.tail(of: file)
        #expect(tail?.contains("{\"a\":1}") == true)
        #expect(tail?.contains("{\"a\":2}") == true)
    }

    @Test func dropsThePartialFirstLineOnALargeFile() throws {
        let filler = String(repeating: "x", count: 2000)
        let lines = (0..<100).map { "{\"n\":\($0),\"pad\":\"\(filler)\"}" }
        let file = try writeFile(lines)
        guard let tail = ClaudeCodeMonitor.tail(of: file) else {
            Issue.record("no tail")
            return
        }
        // Every retained line is a complete record.
        for line in tail.split(separator: "\n") {
            #expect(line.hasPrefix("{"))
            #expect(line.hasSuffix("}"))
        }
    }

    @Test func growsTheWindowForARecordLargerThanTheDefault() throws {
        // One record well over the 64 KB default window, as the last line.
        let huge = String(repeating: "y", count: 200 * 1024)
        let file = try writeFile(["{\"n\":1}", "{\"big\":\"\(huge)\"}"])
        guard let tail = ClaudeCodeMonitor.tail(of: file) else {
            Issue.record("no tail")
            return
        }
        #expect(tail.contains("\"big\""))
        // The record is whole, not a fragment.
        #expect(tail.contains("{\"big\""))
    }

    @Test func aParserCanStillReadTheGrownTail() throws {
        let huge = String(repeating: "z", count: 100 * 1024)
        let file = try writeFile([
            "{\"type\":\"user\",\"pad\":\"\(huge)\"}",
        ])
        guard let tail = ClaudeCodeMonitor.tail(of: file) else {
            Issue.record("no tail")
            return
        }
        #expect(!tail.isEmpty)
    }
}

@MainActor
struct TailCacheTests {
    private func tempFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("f.jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func computesOnceForAnUnchangedFile() throws {
        let file = try tempFile("a\n")
        let cache = TailCache<String>()
        var computeCount = 0
        let modified = Date()
        for _ in 0..<5 {
            _ = cache.value(for: file, size: 2, modified: modified) {
                computeCount += 1
                return "parsed"
            }
        }
        #expect(computeCount == 1)
    }

    @Test func recomputesWhenTheFileChanges() throws {
        let file = try tempFile("a\n")
        let cache = TailCache<String>()
        var computeCount = 0
        let first = Date()
        _ = cache.value(for: file, size: 2, modified: first) {
            computeCount += 1; return "one"
        }
        let second = first.addingTimeInterval(1)
        let value = cache.value(for: file, size: 4, modified: second) {
            computeCount += 1; return "two"
        }
        #expect(computeCount == 2)
        #expect(value == "two")
    }

    @Test func retainDropsUnseenPaths() throws {
        let file = try tempFile("a\n")
        let cache = TailCache<String>()
        let modified = Date()
        _ = cache.value(for: file, size: 2, modified: modified) { "one" }
        cache.retain(paths: [])
        var recomputed = false
        _ = cache.value(for: file, size: 2, modified: modified) {
            recomputed = true; return "again"
        }
        #expect(recomputed)
    }
}
