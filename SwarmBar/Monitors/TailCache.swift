import Foundation

/// Remembers a computed value for a file keyed by its size and
/// modification date. Discovery runs every few seconds over every
/// transcript in the window, and almost none of them change between
/// polls, so re-reading and re-computing them is pure waste.
///
/// Caution for callers: only cache values that do not depend on anything
/// besides the file's bytes. A value derived from the current time (a
/// staleness verdict, for example) would freeze that verdict the moment
/// it is cached, which is a subtler bug than it sounds: the row would
/// stop updating even though nothing is wrong with the cache itself.
///
/// Safe to call from the detached discovery tasks: all access is behind
/// a lock.
final class TailCache<Value>: @unchecked Sendable {
    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: Date
    }

    private var storage: [Key: Value] = [:]
    private let lock = NSLock()

    /// Returns the cached value for this file version, or computes and
    /// stores it. Entries for other versions of the same path are
    /// discarded, so the cache does not grow with edits.
    func value(
        for file: URL, size: Int, modified: Date, compute: () -> Value?
    ) -> Value? {
        let key = Key(path: file.path, size: size, modified: modified)
        lock.lock()
        if let hit = storage[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let fresh = compute() else { return nil }

        lock.lock()
        storage = storage.filter { $0.key.path != file.path }
        storage[key] = fresh
        lock.unlock()
        return fresh
    }

    /// Drops entries for files no longer in the discovery window.
    func retain(paths: Set<String>) {
        lock.lock()
        storage = storage.filter { paths.contains($0.key.path) }
        lock.unlock()
    }
}
