import Foundation

/// Session ids for rows that come from a remote host. A tool's own id is
/// only unique on the machine that minted it: a home directory copied
/// between hosts carries its transcripts, and their ids, along with it.
/// Folding the host's id in keeps two hosts from ever sharing a row, while
/// staying stable across polls so a session keeps its identity, and its
/// place in the popover, for as long as it runs.
enum RemoteIdentity {
    nonisolated static func sessionID(hostID: UUID, localID: UUID) -> UUID {
        StableID.uuid(for: "\(hostID.uuidString):\(localID.uuidString)")
    }
}
