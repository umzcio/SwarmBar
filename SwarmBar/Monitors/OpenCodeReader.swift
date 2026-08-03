import Foundation
import SQLite3

// sqlite3_bind_text needs a destructor telling SQLite whether to copy the
// buffer; -1 cast to the destructor type is SQLite's own SQLITE_TRANSIENT,
// which isn't imported as a symbol by the Swift overlay.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Pure, testable reader over OpenCode's SQLite state at
/// ~/.local/share/opencode/opencode.db. Opens read-only and never writes;
/// callers should treat a missing or unreadable database as "no sessions"
/// rather than an error.
///
/// Schema (only the columns this reader touches):
///   session(id TEXT, directory TEXT, title TEXT,
///           time_created INTEGER ms, time_updated INTEGER ms)
///   message(id TEXT, session_id TEXT, time_created INTEGER ms)
///   part(id TEXT, message_id TEXT, data TEXT)  -- JSON blob
/// part.data's JSON carries at least a "type" (one of text / step-start /
/// step-finish / ...); text parts also carry "text".
enum OpenCodeReader {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60
    nonisolated static let waitingAfter: TimeInterval = 30 * 60
    nonisolated static let recentPartLimit = 20

    nonisolated static func sessions(dbPath: String, now: Date = .now) -> [AgentSession] {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        let sessionSQL = "SELECT id, directory, time_created, time_updated FROM session"
        var sessionStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sessionSQL, -1, &sessionStmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(sessionStmt) }

        var results: [AgentSession] = []
        while sqlite3_step(sessionStmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(sessionStmt, 0) else { continue }
            let id = String(cString: idText)
            let directory = sqlite3_column_text(sessionStmt, 1).map { String(cString: $0) }
            let timeCreated = sqlite3_column_int64(sessionStmt, 2)
            let timeUpdated = sqlite3_column_int64(sessionStmt, 3)
            guard timeUpdated > 0 else { continue }

            let updatedAt = Date(timeIntervalSince1970: TimeInterval(timeUpdated) / 1000)
            let age = now.timeIntervalSince(updatedAt)
            guard age < discoveryWindow else { continue }
            let createdAt = timeCreated > 0
                ? Date(timeIntervalSince1970: TimeInterval(timeCreated) / 1000)
                : updatedAt

            let parts = recentParts(db: db, sessionId: id)
            let status = status(for: parts, age: age)
            let projectPath = directory.map { URL(fileURLWithPath: $0) }

            results.append(AgentSession(
                id: StableID.uuid(for: id),
                tool: .openCode,
                projectName: projectPath?.lastPathComponent ?? id,
                projectPath: projectPath,
                status: status,
                startedAt: createdAt,
                lastActivityAt: updatedAt
            ))
        }
        return demoteSuperseded(results).sorted { $0.startedAt > $1.startedAt }
    }

    /// Every opencode launch auto-creates a session in its directory, and
    /// the database has no record of which sessions still have a live TUI,
    /// so restarts leave a trail of ghosts that would all read as waiting.
    /// Only the most recently active session per directory keeps its
    /// status; older siblings go idle (same policy as Grok's same-pid
    /// session-switch dedupe).
    private nonisolated static func demoteSuperseded(_ sessions: [AgentSession]) -> [AgentSession] {
        var newestByDirectory: [String: Date] = [:]
        for session in sessions {
            let key = session.projectPath?.path ?? session.projectName
            newestByDirectory[key] = max(newestByDirectory[key] ?? .distantPast, session.lastActivityAt)
        }
        return sessions.map { session in
            let key = session.projectPath?.path ?? session.projectName
            guard session.lastActivityAt < newestByDirectory[key] ?? .distantPast else {
                return session
            }
            var demoted = session
            demoted.status = .idle
            return demoted
        }
    }

    private struct PartRow {
        var type: String
        var text: String?
    }

    /// The trailing ~20 parts for a session, newest first (part.rowid DESC),
    /// joined through message to filter by session_id.
    private nonisolated static func recentParts(db: OpaquePointer, sessionId: String) -> [PartRow] {
        let sql = """
        SELECT part.data FROM part
        JOIN message ON part.message_id = message.id
        WHERE message.session_id = ?
        ORDER BY part.rowid DESC
        LIMIT \(recentPartLimit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, sqliteTransient)

        var rows: [PartRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dataText = sqlite3_column_text(stmt, 0) else { continue }
            let json = String(cString: dataText)
            guard let data = json.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            rows.append(PartRow(type: type, text: object["text"] as? String))
        }
        return rows
    }

    /// The trailing part (parts[0], since parts are newest-first) being a
    /// step-start with nothing after it means the turn is still in flight.
    /// Otherwise, a recent finished turn is treated as waiting on the user,
    /// surfacing the last text part as a preview; anything older is idle.
    private nonisolated static func status(for parts: [PartRow], age: TimeInterval) -> SessionStatus {
        if parts.first?.type == "step-start" {
            return .working(activity: "Working…")
        }
        if age < waitingAfter {
            let text = parts.first(where: { $0.type == "text" })?.text
            return .waitingInput(prompt: text.map(firstLine) ?? "")
        }
        return .idle
    }

    private nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 90 ? trimmed : String(trimmed.prefix(90)) + "…"
    }
}
