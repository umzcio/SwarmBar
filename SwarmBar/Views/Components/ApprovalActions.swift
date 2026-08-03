import SwiftUI

struct ApprovalActions: View {
    @Environment(SessionStore.self) private var store
    let session: AgentSession

    var body: some View {
        HStack(spacing: 6) {
            Button("Approve") { store.approve(session) }
                .buttonStyle(ActionPill.approve)
                .accessibilityLabel("Approve")
            Button("Deny") { store.deny(session) }
                .buttonStyle(ActionPill.deny)
                .accessibilityLabel("Deny")
        }
    }
}
