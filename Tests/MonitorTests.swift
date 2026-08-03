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

    @Test func inactiveFreshSessionIsWaitingInput() throws {
        let root = try makeRoot()
        let id = UUID().uuidString
        let now = Date.now
        try writeSession(
            root: root, id: id, cwd: "/tmp/proj-fresh", updatedAt: now.addingTimeInterval(-60),
            preview: "Ready for review, shall I proceed?")
        try writeActive(root: root, ids: [])

        let sessions = GrokBuildMonitor.discover(root: root, now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .waitingInput(prompt: "Ready for review, shall I proceed?"))
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
