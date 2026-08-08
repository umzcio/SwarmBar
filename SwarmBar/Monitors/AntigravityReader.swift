import Foundation
import SQLite3

/// Antigravity (the `agy` CLI, which replaced Google's retired `gemini`)
/// keeps one row per conversation in
/// ~/.gemini/antigravity-cli/conversation_summaries.db. Opened read only and
/// never written, like the OpenCode reader.
///
/// This is by far the friendliest state of any tool SwarmBar watches: the
/// table already carries the session id, a human title, a preview of the
/// last step, the workspace, an activity timestamp, and, unusually, the
/// parent link that says whether a conversation is a subagent. Everything
/// else needed a directory walk and a parser.
///
/// Two columns are read defensively because no sample of them exists yet.
/// Every row on the machine this was written against had an empty `status`
/// and `not_fully_idle` = 0, the newest being weeks old, so the vocabulary
/// of `status` is unknown. Until a live session provides one, recency
/// decides the status the same way it did for Kimi before its wire events
/// were sampled. See `AntigravitySessionState.status(for:)`.
enum AntigravityReader {
    /// A row as it exists on disk, before any interpretation.
    struct Row: Sendable, Equatable {
        let conversationID: String
        let title: String
        let preview: String
        let workspace: String?
        let status: String
        let notFullyIdle: Bool
        let killed: Bool
        let parentID: String
        let lastModified: Date
    }

    nonisolated static func defaultDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
            .path
    }

    /// `workspace_uris` is a JSON array of file URLs. The first entry is the
    /// session's working directory; additional entries come from --add-dir
    /// and are not the project.
    nonisolated static func workspacePath(fromURIs json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let uris = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              let first = uris.first
        else { return nil }
        if let url = URL(string: first), url.isFileURL { return url.path }
        return first.hasPrefix("/") ? first : nil
    }

    nonisolated static func rows(dbPath: String = defaultDatabasePath()) -> [Row] {
        // Straight read-only first. It succeeds whenever the write-ahead log
        // has been checkpointed away, which is the common case.
        if let rows = query(dbPath: dbPath, uri: "file:\(dbPath)?mode=ro") { return rows }

        // It fails while agy holds a hot WAL: a read-only connection cannot
        // create the -shm file SQLite needs, and every statement comes back
        // SQLITE_CANTOPEN. Verified against a real database, where the
        // read-only open SUCCEEDED and only the first prepare failed, so
        // checking the open alone would have reported an empty table rather
        // than an error.
        //
        // `immutable=1` also opens it, and is wrong: it tells SQLite the
        // file cannot change, so the WAL is ignored and the newest
        // conversations, the only ones a status bar cares about, are the
        // exact ones missing.
        //
        // So take a copy and read that. The database is a few tens of KB,
        // the copy is temporary, and the original is still never written to.
        guard let snapshot = snapshot(of: dbPath) else { return [] }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        return query(dbPath: snapshot.path, uri: snapshot.path) ?? []
    }

    /// Copies the database and its sidecars into a throwaway directory so
    /// the WAL can be replayed without touching the original.
    private nonisolated static func snapshot(of dbPath: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("swarmbar-agy-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        let source = URL(fileURLWithPath: dbPath)
        let destination = dir.appendingPathComponent(source.lastPathComponent)
        guard (try? fm.copyItem(at: source, to: destination)) != nil else {
            try? fm.removeItem(at: dir)
            return nil
        }
        // Without these the copy is whatever was last checkpointed.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: dbPath + suffix)
            guard fm.fileExists(atPath: sidecar.path) else { continue }
            try? fm.copyItem(at: sidecar, to: dir.appendingPathComponent(sidecar.lastPathComponent))
        }
        return destination
    }

    /// Returns nil when the database cannot be read, which is different from
    /// an empty table and is what lets the caller fall back.
    private nonisolated static func query(dbPath: String, uri: String) -> [Row]? {
        var db: OpaquePointer?
        let flags = uri.hasPrefix("file:")
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT conversation_id, title, preview, workspace_uris, status,
                   not_fully_idle, killed, parent_conversation_id, last_modified_time
            FROM conversation_summaries
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                guard let c = sqlite3_column_text(statement, column) else { return "" }
                return String(cString: c)
            }
            let id = text(0)
            guard !id.isEmpty else { continue }
            guard let modified = parseTimestamp(text(8)) else { continue }
            rows.append(Row(
                conversationID: id,
                title: text(1),
                preview: text(2),
                workspace: workspacePath(fromURIs: text(3)),
                status: text(4),
                notFullyIdle: sqlite3_column_int64(statement, 5) != 0,
                killed: sqlite3_column_int64(statement, 6) != 0,
                parentID: text(7),
                lastModified: modified
            ))
        }
        return rows
    }

    /// The column is declared `datetime`, which SQLite stores as whatever
    /// the writer put there. Go's driver writes RFC3339; the shell renders
    /// "YYYY-MM-DD HH:MM:SS". Both are accepted, and an unparseable value
    /// drops the row rather than dating it to now, which would park a
    /// months-old conversation at the top of Active.
    nonisolated static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let iso = makeISO(fractional: true).date(from: trimmed) { return iso }
        if let plain = makeISO(fractional: false).date(from: trimmed) { return plain }
        return makeSQLite().date(from: trimmed)
    }

    /// Built per call rather than cached. Formatters are not Sendable, and
    /// a handful of rows every five seconds does not justify the ceremony
    /// of making a shared one safe.
    private nonisolated static func makeISO(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }

    private nonisolated static func makeSQLite() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }
}
