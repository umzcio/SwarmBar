import Foundation

/// Whole-file reads with a ceiling. Monitors read agent state from this Mac
/// and from a remote host's mirror alike, and the mirror's files take the
/// logical size the remote host names: a sparse file of tens of gigabytes
/// costs the host nothing to name and would cost a whole-file read all of
/// it. Every whole-file read of agent state goes through here instead.
enum BoundedRead {
    /// The helper's own ceiling for a file it ships whole (WHOLE_MAX_BYTES
    /// in swarmbar-helper.py). A JSON index or summary past it is not one an
    /// agent wrote, and the helper would never have shipped it.
    nonisolated static let wholeFileLimit = 16 * 1024 * 1024

    /// The file's bytes, or nil when it cannot be read, is not a regular
    /// file, or holds more than `limit` bytes. The size is checked on the
    /// open descriptor, and the read itself stops one byte past the limit,
    /// so a file that grows in between is still refused rather than loaded.
    nonisolated static func data(of url: URL, limit: Int = wholeFileLimit) -> Data? {
        // Non-blocking, so a FIFO planted where a file belongs cannot hang
        // the open; it is then refused as not a regular file.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= off_t(limit)
        else { return nil }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            return nil
        }
        return data.count <= limit ? data : nil
    }
}
