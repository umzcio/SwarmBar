import Foundation
import SQLite3

/// Read-only access to a database another process is actively writing.
///
/// Two of the tools SwarmBar watches keep their state in SQLite, and both
/// run it in WAL mode. A read-only connection cannot create the `-shm` file
/// SQLite needs to read a write-ahead log, and the failure is nastier than
/// it sounds: against a real database the OPEN succeeded and only the first
/// prepare came back SQLITE_CANTOPEN. A reader that checks the open alone
/// reports an empty table rather than an error, so the tool's sessions
/// vanish from the popover with nothing to say why.
///
/// `immutable=1` also opens such a database, and is wrong: it promises
/// SQLite the file cannot change, so the WAL is ignored and the newest
/// rows, the only ones a status bar cares about, are the exact ones
/// missing.
///
/// So read the file directly when that works, and otherwise read a copy.
/// Nothing here ever writes to the original, which is the rule for every
/// monitor.
///
/// The file is not always the tool's. A remote host's databases are
/// mirrored here as the host shipped them, and any account on that host
/// can author the bytes at its own state path. Its schema can define the
/// name a reader queries as a view that never stops producing rows, or as
/// a table whose generated columns compute values as large as SQLite
/// allows, so every connection is held to fixed bounds: each name a reader
/// queries must be an ordinary table with stored columns, no value may
/// pass `maxValueBytes`, and the whole read must finish inside
/// `timeBudget`. A database that breaks any of these is unreadable.
enum SQLiteSnapshot {
    /// The most rows a reader takes from one statement (see `nextRow`).
    nonisolated static let maxRows = 50_000
    /// The largest string or blob any statement may produce. A value in a
    /// stored column is no larger than its file, and the helper ships a
    /// database whole only up to 16 MB.
    nonisolated static let maxValueBytes: Int32 = 16 * 1024 * 1024
    /// The most text and blob bytes a reader takes from one statement.
    nonisolated static let maxResultBytes = 32 * 1024 * 1024
    /// Wall-clock allowance for one connection, every statement included.
    /// An honest read takes milliseconds.
    nonisolated static let timeBudget: TimeInterval = 3

    /// Runs `body` against a read-only connection to the database.
    ///
    /// `body` returns nil to mean "could not read this", which is what
    /// triggers the copy. That distinction has to come from the caller,
    /// since only it knows whether an empty result is a real empty table or
    /// a statement that never prepared.
    ///
    /// `tables` names every table `body` queries. Each one present must be
    /// an ordinary table (not a view or virtual table) with no generated
    /// columns, or the database is refused, as it is when the time budget
    /// runs out. A refusal is not retried against a copy: the copy holds
    /// the same schema.
    nonisolated static func read<T>(
        dbPath: String, tables: [String], _ body: (OpaquePointer) -> T?
    ) -> T? {
        // Straight read-only first. It succeeds whenever SQLite can reach
        // the shared-memory file, which is the common case.
        switch open(uri: directURI(dbPath), flags: directFlags, tables: tables, body) {
        case .value(let value): return value
        case .refused: return nil
        case .unreadable: break
        }

        // The copy is opened read-write so SQLite may replay the log into
        // it. The database is tens of KB, the copy is temporary, and the
        // original is still untouched.
        guard let snapshot = snapshot(of: dbPath) else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        guard case .value(let value) = open(
            uri: snapshot.path, flags: SQLITE_OPEN_READWRITE, tables: tables, body)
        else { return nil }
        return value
    }

    /// The first attempt on its own. Exposed so a test can show that it
    /// really does fail on the database shape this whole type exists for,
    /// rather than passing because the fallback was never needed.
    nonisolated static func readDirect<T>(
        dbPath: String, tables: [String], _ body: (OpaquePointer) -> T?
    ) -> T? {
        guard case .value(let value) = open(
            uri: directURI(dbPath), flags: directFlags, tables: tables, body)
        else { return nil }
        return value
    }

    /// What one statement has handed its reader so far.
    struct Cursor {
        var rows = 0
        var bytes = 0
    }

    /// `sqlite3_step` for a reading loop: true while a row is ready and the
    /// statement has handed over fewer than `maxRows` rows and no more
    /// than `maxResultBytes` of text and blobs. Each stored value is
    /// already capped by `maxValueBytes`, but a crafted file can point many
    /// rows at the same overflow pages, so only a running total bounds what
    /// a reader that keeps its rows can be made to hold. Stopping leaves
    /// the reader with a shorter answer, never an unbounded one.
    nonisolated static func nextRow(_ statement: OpaquePointer?, _ cursor: inout Cursor) -> Bool {
        guard cursor.rows < maxRows, sqlite3_step(statement) == SQLITE_ROW else { return false }
        cursor.rows += 1
        for column in 0..<sqlite3_column_count(statement) {
            // The type first: asking a number for its byte count converts it.
            let type = sqlite3_column_type(statement, column)
            if type == SQLITE_TEXT || type == SQLITE_BLOB {
                cursor.bytes += Int(sqlite3_column_bytes(statement, column))
            }
        }
        return cursor.bytes <= maxResultBytes
    }

    private nonisolated static func directURI(_ dbPath: String) -> String { "file:\(dbPath)?mode=ro" }
    private nonisolated static let directFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI

    private enum Outcome<T> {
        case value(T)
        /// Could not be read here, which a copy may fix.
        case unreadable
        /// Read, and found to break a bound. A copy would break it too.
        case refused
    }

    /// The progress handler's state, reached through the handler's context
    /// pointer since a C callback captures nothing.
    private struct Clock {
        let deadline: UInt64
        var expired = false
    }

    private nonisolated static func open<T>(
        uri: String, flags: Int32, tables: [String], _ body: (OpaquePointer) -> T?
    ) -> Outcome<T> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return .unreadable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        harden(db)

        let clock = UnsafeMutablePointer<Clock>.allocate(capacity: 1)
        clock.initialize(to: Clock(
            deadline: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(timeBudget * 1_000_000_000)))
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            clock.deinitialize(count: 1)
            clock.deallocate()
        }
        // Every 1000 virtual machine instructions, so a statement that
        // would run forever is interrupted within a fraction of a
        // millisecond of the deadline.
        sqlite3_progress_handler(db, 1000, { context in
            guard let context else { return 1 }
            let clock = context.assumingMemoryBound(to: Clock.self)
            guard clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > clock.pointee.deadline else { return 0 }
            clock.pointee.expired = true
            return 1
        }, clock)

        switch plainTables(tables, db: db) {
        case .unreadable: return .unreadable
        case .refused: return .refused
        case .value: break
        }
        let value = body(db)
        // An interrupted statement ends its loop as if the table ran out,
        // so what came back is partial and must not be taken as the answer.
        if clock.pointee.expired { return .refused }
        return value.map { .value($0) } ?? .unreadable
    }

    /// Limits for a file whose author is unknown. The value ceiling is what
    /// bounds a single row; the others cut a crafted schema off from
    /// anything a reader never asks for. trusted_schema off stops the
    /// schema's own SQL calling functions with side effects.
    private nonisolated static func harden(_ db: OpaquePointer) {
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, maxValueBytes)
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 100_000)
        sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(db, SQLITE_LIMIT_VDBE_OP, 100_000)
        sqlite3_exec(db, "PRAGMA trusted_schema = OFF", nil, nil, nil)
    }

    /// Whether every one of `tables` that exists is an ordinary table whose
    /// columns are all stored. A view, a virtual table or a generated
    /// column computes rows or values on read, which is how a few kilobytes
    /// of schema make a reader spin or allocate without bound. A name that
    /// is absent passes: the reader's own prepare then fails as it always
    /// has, which for an optional table (OpenCode 2's) is expected.
    private nonisolated static func plainTables(_ tables: [String], db: OpaquePointer) -> Outcome<Void> {
        for table in tables {
            var statement: OpaquePointer?
            // hidden 1 is a virtual table's column and 2 a VIRTUAL generated
            // one, both computed on read. 3 is a STORED generated column,
            // whose bytes are on disk like any other.
            let sql = """
                SELECT type, (SELECT count(*) FROM pragma_table_xinfo(?1) WHERE hidden IN (1, 2))
                FROM pragma_table_list(?1) WHERE schema = 'main'
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return .unreadable
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, table, -1, transient)
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                continue
            case SQLITE_ROW:
                let type = sqlite3_column_text(statement, 0).map { String(cString: $0) }
                guard type == "table", sqlite3_column_int64(statement, 1) == 0 else { return .refused }
            default:
                return .unreadable
            }
        }
        return .value(())
    }

    private nonisolated static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Copies the database and its sidecars into a throwaway directory so
    /// the log can be replayed without touching the original. Without the
    /// sidecars the copy is only whatever was last checkpointed.
    private nonisolated static func snapshot(of dbPath: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("swarmbar-db-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        let source = URL(fileURLWithPath: dbPath)
        let destination = dir.appendingPathComponent(source.lastPathComponent)
        guard (try? fm.copyItem(at: source, to: destination)) != nil else {
            try? fm.removeItem(at: dir)
            return nil
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: dbPath + suffix)
            guard fm.fileExists(atPath: sidecar.path) else { continue }
            try? fm.copyItem(at: sidecar, to: dir.appendingPathComponent(sidecar.lastPathComponent))
        }
        return destination
    }
}
