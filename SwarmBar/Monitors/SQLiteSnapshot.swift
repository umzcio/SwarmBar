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
enum SQLiteSnapshot {
    /// Runs `body` against a read-only connection to the database.
    ///
    /// `body` returns nil to mean "could not read this", which is what
    /// triggers the copy. That distinction has to come from the caller,
    /// since only it knows whether an empty result is a real empty table or
    /// a statement that never prepared.
    nonisolated static func read<T>(
        dbPath: String, _ body: (OpaquePointer) -> T?
    ) -> T? {
        // Straight read-only first. It succeeds whenever SQLite can reach
        // the shared-memory file, which is the common case.
        if let value = readDirect(dbPath: dbPath, body) { return value }

        // The copy is opened read-write so SQLite may replay the log into
        // it. The database is tens of KB, the copy is temporary, and the
        // original is still untouched.
        guard let snapshot = snapshot(of: dbPath) else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        return open(uri: snapshot.path, flags: SQLITE_OPEN_READWRITE, body)
    }

    /// The first attempt on its own. Exposed so a test can show that it
    /// really does fail on the database shape this whole type exists for,
    /// rather than passing because the fallback was never needed.
    nonisolated static func readDirect<T>(
        dbPath: String, _ body: (OpaquePointer) -> T?
    ) -> T? {
        open(
            uri: "file:\(dbPath)?mode=ro",
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            body
        )
    }

    private nonisolated static func open<T>(
        uri: String, flags: Int32, _ body: (OpaquePointer) -> T?
    ) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        return body(db)
    }

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
