import Foundation

/// Session ids for rows that come from a remote host. A tool's own id is
/// only unique within the home that minted it: a home directory copied to
/// another host, or to another user on the same host, carries its
/// transcripts, and their ids, along with it. Folding in the host's id and
/// the home's remote path keeps two such copies from ever sharing a row,
/// while staying stable across polls so a session keeps its identity, and
/// its place in the popover, for as long as it runs. A remote hook event
/// names its home too, so the hook path can compute the same id.
enum RemoteIdentity {
    nonisolated static func sessionID(hostID: UUID, home: String, localID: UUID) -> UUID {
        StableID.uuid(for: "\(hostID.uuidString):\(home):\(localID.uuidString)")
    }
}
