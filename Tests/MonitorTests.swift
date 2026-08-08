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
        CREATE TABLE session(id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, parent_id TEXT);
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
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('s1', '/tmp/proj-1', 'title', \(updated - 1000), \(updated));
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
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('s2', '/tmp/proj-2', 'title', \(updated - 1000), \(updated));
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
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('s3', '/tmp/proj-3', 'title', \(updated - 1000), \(updated));
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
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('ghost', '/tmp/proj-4', 'title', \(older - 1000), \(older));
        INSERT INTO message VALUES ('m4', 'ghost', \(older));
        INSERT INTO part VALUES ('p1', 'm4', '{"type":"text","text":"abandoned"}');
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('live', '/tmp/proj-4', 'title', \(newer - 1000), \(newer));
        INSERT INTO message VALUES ('m5', 'live', \(newer));
        INSERT INTO part VALUES ('p2', 'm5', '{"type":"step-start"}');
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('other', '/tmp/proj-5', 'title', \(older - 1000), \(older));
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
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('live', '/tmp/proj-live', 'title', \(updated - 1000), \(updated));
        INSERT INTO message VALUES ('m1', 'live', \(updated));
        INSERT INTO part VALUES ('p1', 'm1', '{"type":"step-start"}');
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('dead', '/tmp/proj-dead', 'title', \(updated - 1000), \(updated));
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

/// The Kimi-family engine changed state.json's shape in 0.34.0. These are
/// the two keys `discover` reads from it, and both moved at once.
///
/// The bug this guards is quiet: with both returning nil the monitor still
/// worked, because the session index supplies the working directory and the
/// wire log's mtime supplies a timestamp. It only bites a session new enough
/// to have no wire log yet, which `discover` then skips entirely.
@MainActor
struct KimiStateShapeTests {
    @Test func readsBothSpellingsOfTheWorkingDirectory() {
        // Pre-0.34.0
        #expect(KimiMonitor.stateWorkDir(["workDir": "/a"]) == "/a")
        // 0.34.0 renamed it
        #expect(KimiMonitor.stateWorkDir(["cwd": "/b"]) == "/b")
        // A state dir outlives an upgrade, so both can be present
        #expect(KimiMonitor.stateWorkDir(["workDir": "/a", "cwd": "/b"]) == "/a")
        #expect(KimiMonitor.stateWorkDir([:]) == nil)
        #expect(KimiMonitor.stateWorkDir(nil) == nil)
    }

    @Test func readsTheIsoStringTheOldEngineWrote() {
        let parsed = KimiMonitor.stateUpdatedAt(["updatedAt": "2026-08-01T10:00:00.000Z"])
        #expect(parsed != nil)
    }

    @Test func readsTheEpochMillisecondsTheNewEngineWrites() {
        // The real value observed in a 0.34.0 session directory.
        let parsed = KimiMonitor.stateUpdatedAt(["updatedAt": 1_786_160_685_042 as Double])
        #expect(parsed == Date(timeIntervalSince1970: 1_786_160_685.042))
    }

    /// Milliseconds read as seconds would land tens of thousands of years
    /// out and the session would sit outside the discovery window forever,
    /// so the scale is decided by magnitude rather than assumed.
    @Test func secondsAndMillisecondsAreBothUnderstood() {
        let millis = KimiMonitor.stateUpdatedAt(["updatedAt": 1_786_160_685_042 as Double])
        let seconds = KimiMonitor.stateUpdatedAt(["updatedAt": 1_786_160_685 as Double])
        #expect(millis == seconds.map { $0.addingTimeInterval(0.042) })
    }

    @Test func rejectsJunkRatherThanInventingADate() {
        #expect(KimiMonitor.stateUpdatedAt([:]) == nil)
        #expect(KimiMonitor.stateUpdatedAt(nil) == nil)
        #expect(KimiMonitor.stateUpdatedAt(["updatedAt": 0 as Double]) == nil)
        #expect(KimiMonitor.stateUpdatedAt(["updatedAt": "not a date"]) == nil)
    }
}

/// Grok gives every subagent its own session directory beside its parent's,
/// so walking the directory listing turned one run into a row per subagent.
/// They all carried the project's name and flipped between Active and
/// Recent as they started and finished.
@MainActor
struct GrokSubagentTests {
    private func makeTree() throws -> (root: URL, dirs: [URL]) {
        let fm = FileManager.default
        let cwdDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Shaped after a real capture: one parent declaring three subagents,
        // plus an unrelated top-level session that spawned nothing.
        let parent = cwdDir.appendingPathComponent("019fdf57-parent")
        let children = ["019fdf7a-a", "019fdf7a-b", "019fdf7a-c"]
        let loner = cwdDir.appendingPathComponent("019fcad1-loner")
        for child in children {
            try fm.createDirectory(
                at: parent.appendingPathComponent("subagents/\(child)"),
                withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: loner, withIntermediateDirectories: true)
        var dirs = [parent, loner]
        for child in children {
            let dir = cwdDir.appendingPathComponent(child)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            dirs.append(dir)
        }
        return (cwdDir, dirs)
    }

    @Test func subagentsAreIdentifiedFromTheParentsListing() throws {
        let (_, dirs) = try makeTree()
        let ids = GrokBuildMonitor.subagentIDs(in: dirs)
        #expect(ids == ["019fdf7a-a", "019fdf7a-b", "019fdf7a-c"])
    }

    /// The parent stays. It is the session the user is actually talking to.
    @Test func theParentIsNotMistakenForItsOwnChild() throws {
        let (_, dirs) = try makeTree()
        let ids = GrokBuildMonitor.subagentIDs(in: dirs)
        #expect(!ids.contains("019fdf57-parent"))
    }

    /// A top-level session that never spawned anything has no subagents
    /// directory, which must not be read as "is a subagent". Guessing from
    /// the child's shape rather than the parent's declaration would lose it.
    @Test func aSessionThatSpawnedNothingSurvives() throws {
        let (_, dirs) = try makeTree()
        let ids = GrokBuildMonitor.subagentIDs(in: dirs)
        #expect(!ids.contains("019fcad1-loner"))
    }

    @Test func noSubagentsMeansNothingIsFiltered() {
        #expect(GrokBuildMonitor.subagentIDs(in: []).isEmpty)
    }
}

/// OpenCode records a spawned session's parent in `session.parent_id`.
/// Those are subagents and must not become rows: every other tool that
/// stores subagents beside their parent leaked them into the popover,
/// where they share the project's name and can never need the user.
@MainActor
struct OpenCodeSubagentTests {
    @Test func childSessionsAreExcluded() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let now = Date.now
        let updated = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let sql = """
        CREATE TABLE session(id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, parent_id TEXT);
        CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER);
        CREATE TABLE part(id TEXT, message_id TEXT, data TEXT);
        INSERT INTO session (id, directory, title, time_created, time_updated) VALUES ('parent', '/tmp/proj', 't', \(updated - 1000), \(updated));
        INSERT INTO session (id, directory, title, time_created, time_updated, parent_id) VALUES ('child', '/tmp/proj', 't', \(updated - 1000), \(updated), 'parent');
        INSERT INTO message VALUES ('m1', 'parent', \(updated));
        INSERT INTO part VALUES ('p1', 'm1', '{"type":"step-start"}');
        INSERT INTO message VALUES ('m2', 'child', \(updated));
        INSERT INTO part VALUES ('p2', 'm2', '{"type":"step-start"}');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let sessions = OpenCodeReader.sessions(dbPath: path, now: now)
        #expect(sessions.count == 1, "the child session should not be a row")
        #expect(sessions.first?.projectName == "proj")
    }
}

/// Antigravity (`agy`) keeps one row per conversation in a sqlite table.
/// The interpretation is deliberately conservative: every row sampled when
/// this was written had an empty `status` and `not_fully_idle` = 0, so the
/// vocabulary is unknown and nothing may be invented from it.
@MainActor
struct AntigravityTests {
    private func row(
        id: String = "c1", title: String = "Fix the parser", preview: String = "Editing",
        workspace: String? = "/Users/x/proj", status: String = "",
        busy: Bool = false, killed: Bool = false, parent: String = "",
        modified: Date = .now
    ) -> AntigravityReader.Row {
        .init(conversationID: id, title: title, preview: preview, workspace: workspace,
              status: status, notFullyIdle: busy, killed: killed,
              parentID: parent, lastModified: modified)
    }

    // MARK: - Workspace

    @Test func theWorkspaceComesOutOfTheFileURIArray() {
        #expect(AntigravityReader.workspacePath(fromURIs: #"["file:///Users/x/proj"]"#) == "/Users/x/proj")
    }

    /// --add-dir appends more entries. Only the first is the project.
    @Test func extraWorkspacesDoNotChangeTheProject() {
        let json = #"["file:///Users/x/proj","file:///Users/x/other"]"#
        #expect(AntigravityReader.workspacePath(fromURIs: json) == "/Users/x/proj")
    }

    @Test func aMissingOrJunkWorkspaceIsNil() {
        #expect(AntigravityReader.workspacePath(fromURIs: "[]") == nil)
        #expect(AntigravityReader.workspacePath(fromURIs: "") == nil)
        #expect(AntigravityReader.workspacePath(fromURIs: "not json") == nil)
    }

    // MARK: - Timestamps

    /// The column is declared `datetime`, which SQLite does not enforce, so
    /// both the shell rendering and the RFC3339 a Go driver writes appear.
    @Test func bothTimestampSpellingsParse() {
        #expect(AntigravityReader.parseTimestamp("2026-08-08 15:04:05") != nil)
        #expect(AntigravityReader.parseTimestamp("2026-08-08T15:04:05Z") != nil)
        #expect(AntigravityReader.parseTimestamp("2026-08-08T15:04:05.123Z") != nil)
    }

    /// An unreadable timestamp drops the row. Defaulting to now would park
    /// a months-old conversation at the top of Active forever.
    @Test func anUnreadableTimestampIsNilRatherThanNow() {
        #expect(AntigravityReader.parseTimestamp("") == nil)
        #expect(AntigravityReader.parseTimestamp("whenever") == nil)
    }

    // MARK: - Subagents

    /// The child names its parent, so the child is what gets filtered. Same
    /// conclusion as Grok, Codex and OpenCode: read the tool's own
    /// statement of parentage.
    @Test func subagentConversationsAreNotRows() {
        let sessions = AntigravityMonitor.discover(
            rows: [row(id: "parent"), row(id: "child", parent: "parent")], now: .now)
        #expect(sessions.count == 1)
    }

    // MARK: - Status

    @Test func aKilledConversationIsDone() {
        let status = AntigravitySessionState.status(for: row(killed: true), age: 5)
        if case .done = status {} else { Issue.record("expected done, got \(status)") }
    }

    @Test func theBusyFlagMeansWorking() {
        let status = AntigravitySessionState.status(for: row(busy: true), age: 9_999)
        if case .working = status {} else { Issue.record("expected working, got \(status)") }
    }

    /// With no flags set, recency decides, exactly as Kimi did before its
    /// events had been sampled.
    @Test func recencyDecidesWhenTheDatabaseSaysNothing() {
        if case .working = AntigravitySessionState.status(for: row(), age: 10) {} else {
            Issue.record("recent should read as working")
        }
        #expect(AntigravitySessionState.status(for: row(), age: 3600) == .idle)
    }

    /// The important property: an unrecognised status must express no
    /// opinion so recency still applies. Guessing a state from an unknown
    /// string is how a row ends up confidently wrong.
    @Test func anUnknownStatusStringIsNotInterpreted() {
        #expect(AntigravitySessionState.mappedStatus("", row: row()) == nil)
        #expect(AntigravitySessionState.mappedStatus("something_new", row: row()) == nil)
    }

    @Test func aStaleConversationIsNotARowAtAll() {
        let old = Date.now.addingTimeInterval(-9 * 60 * 60)
        #expect(AntigravityMonitor.discover(rows: [row(modified: old)], now: .now).isEmpty)
    }

    /// The title is real, human text here, unlike most tools, so it is kept
    /// for the row tooltip while the project name stays the label.
    @Test func theTitleIsCarriedOntoTheSession() {
        let sessions = AntigravityMonitor.discover(rows: [row()], now: .now)
        #expect(sessions.first?.title == "Fix the parser")
        #expect(sessions.first?.projectName == "proj")
    }
}

/// The half that matters for a status bar: a conversation gains its
/// summaries row only when it ENDS, so a live session is invisible to the
/// table and has to be found from the presence lock, history.jsonl and the
/// transcript instead.
@MainActor
struct AntigravityLiveSessionTests {
    private let home = URL(fileURLWithPath: "/tmp/agy-home")

    private func historyEntry(
        workspace: String = "/Users/x/proj", prompt: String = "what does the server do",
        sentAt: Date = .now
    ) -> AntigravityReader.HistoryEntry {
        .init(workspace: workspace, prompt: prompt, sentAt: sentAt)
    }

    // MARK: - Discovery

    /// The bug this whole path exists to fix: with agy running there is no
    /// summaries row at all, and the monitor showed nothing.
    @Test func aLiveConversationIsARowWithNoDatabaseEntry() {
        let sessions = AntigravityMonitor.discover(
            home: home,
            rows: [],
            live: ["live-id": 4242],
            history: ["live-id": historyEntry()],
            transcript: { _ in try? fixture("agy-working") },
            now: .now
        )
        #expect(sessions.count == 1)
        #expect(sessions.first?.projectName == "proj")
        #expect(sessions.first?.pid == 4242)
        #expect(sessions.first?.processAlive == true)
    }

    /// The lock outranks the table. A conversation that appears in both
    /// must not produce two rows, and the live reading is the true one.
    @Test func aLiveConversationIsNotAlsoListedFromTheTable() {
        let row = AntigravityReader.Row(
            conversationID: "live-id", title: "t", preview: "p",
            workspace: "/Users/x/proj", status: "", notFullyIdle: false,
            killed: false, parentID: "", lastModified: .now)
        let sessions = AntigravityMonitor.discover(
            home: home, rows: [row], live: ["live-id": 1],
            history: ["live-id": historyEntry()],
            transcript: { _ in try? fixture("agy-done") }, now: .now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.pid == 1)
    }

    /// A live session between turns still belongs in Active, so the
    /// discovery window that retires stale table rows must not apply to it.
    /// The held lock is the evidence and it outranks any timestamp.
    @Test func aLiveConversationSurvivesTheDiscoveryWindow() {
        let old = Date.now.addingTimeInterval(-20 * 60 * 60)
        let sessions = AntigravityMonitor.discover(
            home: home, live: ["live-id": 7],
            history: ["live-id": historyEntry(sentAt: old)],
            transcript: { _ in nil }, now: .now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.processAlive == true)
    }

    /// history.jsonl is the only record of a running conversation's
    /// workspace, so without it the row has no project to name.
    @Test func withoutHistoryTheLiveRowStillAppears() {
        let sessions = AntigravityMonitor.discover(
            home: home, live: ["live-id": 7], transcript: { _ in nil }, now: .now)
        #expect(sessions.first?.projectName == "agy session")
        #expect(sessions.first?.projectPath == nil)
    }

    // MARK: - The presence lock

    @Test func theLockFilenameIsTheConversationID() {
        #expect(AntigravityReader.conversationID(
            fromLockPath: "/Users/x/.gemini/antigravity-cli/presence/abc-123.lock") == "abc-123")
    }

    @Test func aPathThatIsNotALockIsNotASession() {
        #expect(AntigravityReader.conversationID(fromLockPath: "/tmp/notes.txt") == nil)
        #expect(AntigravityReader.conversationID(fromLockPath: "/tmp/.lock") == nil)
    }

    // MARK: - history.jsonl

    @Test func historyMapsConversationsToWorkspaces() {
        let text = """
            {"display":"first","timestamp":1786223614380,"workspace":"/a","conversationId":"c1"}
            {"display":"second","timestamp":1786223769712,"workspace":"/b","conversationId":"c2"}
            """
        let entries = AntigravityReader.history(atPath: "", tail: text)
        #expect(entries["c1"]?.workspace == "/a")
        #expect(entries["c2"]?.prompt == "second")
    }

    /// One line per prompt, so a long conversation has many. The newest is
    /// the workspace it is in now.
    @Test func theLastLineForAConversationWins() {
        let text = """
            {"display":"first","timestamp":1,"workspace":"/old","conversationId":"c1"}
            {"display":"second","timestamp":2,"workspace":"/new","conversationId":"c1"}
            """
        #expect(AntigravityReader.history(atPath: "", tail: text)["c1"]?.workspace == "/new")
    }

    @Test func junkHistoryLinesAreSkipped() {
        let text = """
            not json
            {"display":"no id","timestamp":1,"workspace":"/a"}
            {"display":"ok","timestamp":1786223614380,"workspace":"/a","conversationId":"c1"}
            """
        #expect(AntigravityReader.history(atPath: "", tail: text).count == 1)
    }
}

/// The transcript names its steps where the conversation database numbers
/// them, so it, not the database, is what the status is read from.
@MainActor
struct AntigravityTranscriptTests {
    private func steps(_ name: String) throws -> [AntigravityTranscript.Step] {
        AntigravityTranscript.steps(in: try fixture(name))
    }

    @Test func aTrailingPlannerResponseWithToolCallsIsRunningTool() throws {
        let status = AntigravityTranscript.status(for: try steps("agy-running-tool"))
        #expect(status == .runningTool(activity: "Viewing server.js"))
    }

    /// A tool result with no planner step after it means the model is still
    /// mid-turn. This fixture also has its lines out of order, which is how
    /// the real file is written.
    @Test func aTrailingToolResultIsWorking() throws {
        let status = AntigravityTranscript.status(for: try steps("agy-working"))
        #expect(status == .working(activity: "List directory"))
    }

    /// The turn boundary: a planner response with text and no tool calls.
    @Test func aTrailingPlannerResponseWithTextEndsTheTurn() throws {
        let status = AntigravityTranscript.status(for: try steps("agy-done"))
        if case .done(let summary) = status {
            #expect(summary.hasPrefix("The server is a small Express app"))
        } else {
            Issue.record("expected done, got \(String(describing: status))")
        }
    }

    /// Steps arrive out of order, so the newest is the highest index and
    /// never simply the last line.
    @Test func stepsAreOrderedByIndexNotByLine() throws {
        let parsed = try steps("agy-working")
        #expect(parsed.map(\.index) == [0, 1, 2, 3])
    }

    /// SYSTEM steps are scaffolding the runtime writes around a turn, and
    /// one of them is usually the newest line even while the agent works.
    @Test func systemStepsDoNotDecideTheStatus() {
        let text = """
            {"step_index":0,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"All set."}
            {"step_index":1,"source":"SYSTEM","type":"EPHEMERAL_MESSAGE","status":"DONE","content":"scaffolding"}
            """
        let status = AntigravityTranscript.status(for: AntigravityTranscript.steps(in: text))
        if case .done = status {} else {
            Issue.record("the system step should not have decided this")
        }
    }

    /// A user prompt with nothing after it means the agent owes a reply.
    @Test func aTrailingUserInputIsWorking() {
        let text = #"""
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nfix the build\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nignore me\n</ADDITIONAL_METADATA>"}
            """#
        #expect(AntigravityTranscript.status(for: AntigravityTranscript.steps(in: text))
            == .working(activity: "fix the build"))
    }

    /// A finished turn that asks something is waiting on the user, which is
    /// the same rule every other tool's transcript gets.
    @Test func aFinishedTurnThatAsksSomethingWaits() {
        let text = """
            {"step_index":0,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Which file did you mean?"}
            """
        let status = AntigravityTranscript.status(for: AntigravityTranscript.steps(in: text))
        if case .waitingInput = status {} else {
            Issue.record("expected waiting on you, got \(String(describing: status))")
        }
    }

    @Test func anEmptyOrUnreadableTranscriptHasNoOpinion() {
        #expect(AntigravityTranscript.status(for: []) == nil)
        #expect(AntigravityTranscript.steps(in: "not json\n\n").isEmpty)
    }

    /// Every value in a tool call's args is a JSON document encoded as a
    /// string, so a plain string arrives wrapped in its own quotes.
    @Test func toolArgumentsAreDoubleEncoded() {
        #expect(AntigravityTranscript.unwrapJSONString("\"Viewing server.js\"") == "Viewing server.js")
        #expect(AntigravityTranscript.unwrapJSONString("Viewing server.js") == "Viewing server.js")
    }

    /// A tool call with no toolAction still names its tool.
    @Test func aToolCallWithoutAnActionFallsBackToItsName() {
        let calls: [[String: Any]] = [["name": "run_command", "args": [:]]]
        #expect(AntigravityTranscript.toolActions(calls) == ["Run command"])
    }

    @Test func typeNamesAreHumanized() {
        #expect(AntigravityTranscript.humanize("LIST_DIRECTORY") == "List directory")
        #expect(AntigravityTranscript.humanize("VIEW_FILE") == "View file")
    }
}

/// Both SQLite-backed tools run their databases in WAL mode, and a
/// read-only connection cannot create the `-shm` file SQLite then needs.
/// Against a real database the OPEN succeeded and only the first prepare
/// failed with SQLITE_CANTOPEN, so a reader that checks the open alone
/// reports an empty table instead of an error, and the tool's sessions
/// disappear from the popover with nothing to say why.
///
/// These tests hinge on the fixture actually reproducing that shape, so the
/// first one is a negative control: it asserts the plain read-only path
/// FAILS here. Without it the rest would pass just as happily against a
/// database that never needed the fallback, which is no evidence at all.
@MainActor
struct SQLiteWALFallbackTests {
    /// A WAL database with no shared-memory file, in a directory that
    /// cannot be written, so SQLite cannot make one. That is the state a
    /// writing process leaves behind, and it is what defeats a read-only
    /// connection.
    private func makeWALDatabaseWithoutSharedMemory(
        table: String, insert: String
    ) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, table, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try? FileManager.default.removeItem(atPath: path + "-shm")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: dir.path)
        return path
    }

    private func canQuery(_ path: String, table: String, direct: Bool) -> Bool {
        let probe: (OpaquePointer) -> Bool? = { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT count(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK
            else { return nil }
            sqlite3_finalize(statement)
            return true
        }
        let result = direct
            ? SQLiteSnapshot.readDirect(dbPath: path, probe)
            : SQLiteSnapshot.read(dbPath: path, probe)
        return result ?? false
    }

    private var summariesTable: String {
        """
        CREATE TABLE conversation_summaries(
          conversation_id text, title text, preview text, workspace_uris text,
          status text, not_fully_idle numeric, killed numeric,
          parent_conversation_id text, last_modified_time datetime);
        """
    }

    private var summariesRow: String {
        """
        INSERT INTO conversation_summaries VALUES
          ('c1','Title','Preview','["file:///tmp/proj"]','',0,0,'','2026-08-08 15:00:00');
        """
    }

    /// The negative control. If this ever passes, the fixture stopped
    /// reproducing the problem and every other test here proves nothing.
    @Test func aPlainReadOnlyConnectionCannotReadThisDatabase() throws {
        let path = try makeWALDatabaseWithoutSharedMemory(
            table: summariesTable, insert: summariesRow)
        #expect(canQuery(path, table: "conversation_summaries", direct: true) == false)
    }

    @Test func theSnapshotFallbackReadsItAnyway() throws {
        let path = try makeWALDatabaseWithoutSharedMemory(
            table: summariesTable, insert: summariesRow)
        #expect(canQuery(path, table: "conversation_summaries", direct: false))
    }

    @Test func antigravityRowsSurviveIt() throws {
        let path = try makeWALDatabaseWithoutSharedMemory(
            table: summariesTable, insert: summariesRow)
        let rows = AntigravityReader.rows(dbPath: path)
        #expect(rows.count == 1, "a WAL database must not read as an empty table")
        #expect(rows.first?.workspace == "/tmp/proj")
    }

    /// OpenCode has never actually hit this: it leaves a readable -shm
    /// beside its database, which is the only reason its plain read-only
    /// connection has been working. That is a property of how the tool
    /// happens to run, not a guarantee.
    @Test func openCodeSessionsSurviveIt() throws {
        let now = Date.now
        let updated = Int(now.timeIntervalSince1970 * 1000)
        let path = try makeWALDatabaseWithoutSharedMemory(
            table: """
                CREATE TABLE session(
                  id TEXT, directory TEXT, title TEXT, parent_id TEXT,
                  time_created INTEGER, time_updated INTEGER);
                CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER);
                CREATE TABLE part(id TEXT, message_id TEXT, data TEXT);
                """,
            insert: """
                INSERT INTO session VALUES
                  ('s1','/tmp/proj','Title',NULL,\(updated),\(updated));
                """
        )
        let sessions = OpenCodeReader.sessions(dbPath: path, now: now)
        #expect(sessions.count == 1, "a WAL database must not read as no sessions")
        #expect(sessions.first?.projectName == "proj")
    }

    @Test func aMissingDatabaseIsEmptyRatherThanACrash() {
        #expect(AntigravityReader.rows(dbPath: "/nope/missing.db").isEmpty)
        #expect(OpenCodeReader.sessions(dbPath: "/nope/missing.db").isEmpty)
    }
}
