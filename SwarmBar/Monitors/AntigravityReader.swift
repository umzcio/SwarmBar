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

    /// One conversation's workspace and the time its last prompt was sent,
    /// as recorded in history.jsonl.
    struct HistoryEntry: Sendable, Equatable {
        let workspace: String
        let prompt: String
        let sentAt: Date
    }

    nonisolated static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli")
    }

    nonisolated static func defaultDatabasePath() -> String {
        defaultHome().appendingPathComponent("conversation_summaries.db").path
    }

    /// Where a live session's own state lives. The id is the conversation
    /// id, which the presence lock names outright.
    nonisolated static func transcriptPath(home: URL, conversationID: String) -> URL {
        home
            .appendingPathComponent("brain")
            .appendingPathComponent(conversationID)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl")
    }

    nonisolated static func presenceDirectory(home: URL) -> URL {
        home.appendingPathComponent("presence")
    }

    /// The conversation id a presence lock is named for, or nil if the path
    /// is not one.
    nonisolated static func conversationID(fromLockPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".lock") else { return nil }
        let id = String(name.dropLast(".lock".count))
        return id.isEmpty ? nil : id
    }

    /// Every live conversation, mapped to the pid running it.
    nonisolated static func liveConversations(home: URL = defaultHome()) -> [String: Int] {
        let held = ProcessLiveness.openFiles(
            processName: "agy", inDirectory: presenceDirectory(home: home).path)
        var live: [String: Int] = [:]
        for (path, pid) in held {
            guard let id = conversationID(fromLockPath: path) else { continue }
            live[id] = pid
        }
        return live
    }

    /// history.jsonl is the only place a RUNNING session's workspace is
    /// written down: the summaries table gains its row when a conversation
    /// ends, so a live one has no row to read a workspace from. One line per
    /// prompt, newest last, and the last line for an id wins because that is
    /// the workspace the session is in now.
    nonisolated static func history(
        atPath path: String, tail: String? = nil
    ) -> [String: HistoryEntry] {
        let text = tail ?? ClaudeCodeMonitor.tail(of: URL(fileURLWithPath: path)) ?? ""
        var entries: [String: HistoryEntry] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = json["conversationId"] as? String, !id.isEmpty,
                  let workspace = json["workspace"] as? String, !workspace.isEmpty
            else { continue }
            // Milliseconds since the epoch, unlike every timestamp in the
            // summaries table, which are datetime strings.
            let millis = (json["timestamp"] as? Double) ?? 0
            entries[id] = HistoryEntry(
                workspace: workspace,
                prompt: json["display"] as? String ?? "",
                sentAt: Date(timeIntervalSince1970: millis / 1000)
            )
        }
        return entries
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
        SQLiteSnapshot.read(dbPath: dbPath, query) ?? []
    }

    /// Returns nil when the database cannot be read, which is different from
    /// an empty table and is what lets SQLiteSnapshot fall back to a copy.
    private nonisolated static func query(db: OpaquePointer) -> [Row]? {
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
