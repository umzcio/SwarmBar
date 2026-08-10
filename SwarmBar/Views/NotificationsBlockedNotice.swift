import SwiftUI

/// Says, where the user already looks, that macOS is dropping every alert.
///
/// The Settings pane says this too, but Settings is the one place you only
/// open once you already suspect something is wrong, and that is exactly
/// how this went unnoticed for the app's whole life: three switches on,
/// every notification refused, nothing anywhere to say so.
///
/// Deliberately not a preference. A switch reading "tell me when my alerts
/// are broken" is one nobody knowingly turns off, so it would be a setting
/// that exists only to be left alone. It is dismissible instead, which is
/// the same thing for anyone who does not care, without adding a fourth
/// row to a pane that has three.
struct NotificationsBlockedNotice: View {
    @AppStorage("notifyApprovals") private var notifyApprovals = true
    @AppStorage("notifyWaiting") private var notifyWaiting = false
    @AppStorage("notifySound") private var notifySound = true
    @AppStorage("dismissedNotificationsBlocked") private var dismissed = false

    @State private var systemAllows: Bool?

    /// Only worth saying when SwarmBar is actually trying to send
    /// something. With all three switches off nothing is broken, and
    /// warning anyway is the noise that teaches people to ignore warnings.
    private var wantsToNotify: Bool { notifyApprovals || notifyWaiting }

    var body: some View {
        if systemAllows == false, wantsToNotify, !dismissed {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(.orange)
                Text("macOS is blocking notifications")
                    .swarmFont(.meta)
                Spacer(minLength: 6)
                Button("Fix") { AgentNotifier.openSystemSettings() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .swarmFont(.meta)
                    .accessibilityLabel("Open notification settings")
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            .task { await refresh() }
        } else {
            // Still has to run when hidden: this is how the notice appears
            // after permission is revoked while the popover is open.
            Color.clear.frame(height: 0).task { await refresh() }
        }
    }

    /// Asked each time the popover opens rather than cached, since the
    /// permission can be granted or revoked while SwarmBar runs. Granting
    /// it also clears a previous dismissal, so the notice is available
    /// again if it is ever revoked a second time.
    private func refresh() async {
        let allowed = await AgentNotifier.isAllowed()
        systemAllows = allowed
        if allowed { dismissed = false }
    }
}
