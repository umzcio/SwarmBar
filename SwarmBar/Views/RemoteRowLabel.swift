import Foundation

/// Pure labelling for remote rows, kept out of the view so it is testable.
enum RemoteRowLabel {
    static func badge(for session: AgentSession) -> String? {
        session.host
    }

    /// A host going away does not end its sessions. The row keeps its last
    /// known status and says the host cannot be reached, because marking it
    /// ended would be a lie and dropping it would look like the work
    /// finished.
    static func unreachableNote(
        host: String?, reachability: [String: RemoteReachability]
    ) -> String? {
        guard let host, case .unreachable = reachability[host] else { return nil }
        return "Cannot reach \(host)"
    }
}
