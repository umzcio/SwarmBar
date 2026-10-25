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

    /// Shown in place of Approve and Deny on a remote prompt nothing here
    /// can answer: no held request, no tmux pane, or approvals switched off
    /// for that tool on that host. Buttons that silently did nothing would
    /// leave the user waiting on an agent that is waiting on them.
    static func terminalOnlyNote(host: String) -> String {
        "Answer in the terminal on \(host)"
    }
}
