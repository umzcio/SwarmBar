import SwiftUI

struct ApprovalActions: View {
    @Environment(SessionStore.self) private var store
    let session: AgentSession

    private var prompt: ApprovalPrompt? {
        if case .waitingApproval(let prompt) = session.status { return prompt }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            if prompt?.offersApprove ?? false {
                Button("Approve") { store.approve(session) }
                    .buttonStyle(ActionPill.approve)
                    .accessibilityLabel("Approve")
                Button("Deny") { store.deny(session) }
                    .buttonStyle(ActionPill.deny)
                    .accessibilityLabel("Deny")
            } else if let host = session.host {
                // A remote row's terminal is on its host, never here.
                Text(RemoteRowLabel.terminalOnlyNote(host: host))
                    .swarmFont(.meta)
                    .foregroundStyle(.secondary)
            } else if session.projectPath != nil {
                // Nothing here can show what Approve would allow, so the
                // row offers the place that can.
                Button("Open terminal") { store.openInTerminal(session) }
                    .buttonStyle(ActionPill.deny)
                    .accessibilityLabel("Open terminal")
            }
        }
    }
}
