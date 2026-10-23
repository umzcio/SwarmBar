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

    func noteApplied(_ snapshot: RemoteSnapshot) {
        lastSnapshot = snapshot
    }
}
