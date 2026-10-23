import Foundation

/// Everything SwarmBar holds open for one running host: the helper channel,
/// the mirror its snapshots fill, and the last snapshot that was applied in
/// full. The monitor polls through it, and answering and relaying go
/// through the same channel, so a host never has more than one helper
/// process.
@MainActor
final class RemoteHostConnection {
    let host: RemoteHost
    let channel: SSHChannel
    let mirror: RemoteMirror
    /// Only ever a snapshot whose bytes are all in the mirror, so whatever
    /// it names (a pid, a pane, a path) can be found there too.
    private(set) var lastSnapshot: RemoteSnapshot?

    init(host: RemoteHost, channel: SSHChannel, mirror: RemoteMirror) {
        self.host = host
        self.channel = channel
        self.mirror = mirror
    }

    /// Returns whether any process's pane differs from the previous
    /// snapshot's, a pane appearing or vanishing included, so the caller
    /// can redraw the rows whose buttons depend on one.
    @discardableResult
    func noteApplied(_ snapshot: RemoteSnapshot) -> Bool {
        let changed = Self.panes(of: lastSnapshot) != Self.panes(of: snapshot)
        lastSnapshot = snapshot
        return changed
    }

    /// The helper went away or a poll failed. Which pane each process sat
    /// in is only known as of before the gap, and a pane can be closed,
    /// reused or handed to another program while nobody is looking, so no
    /// key is aimed by it until a fresh snapshot lands. Returns whether
    /// there was a snapshot to forget.
    @discardableResult
    func noteLost() -> Bool {
        guard lastSnapshot != nil else { return false }
        lastSnapshot = nil
        return true
    }

    private static func panes(of snapshot: RemoteSnapshot?) -> [Int: RemotePane] {
        var panes: [Int: RemotePane] = [:]
        for process in snapshot?.processes ?? [] {
            if let pane = process.pane { panes[process.pid] = pane }
        }
        return panes
    }
}
