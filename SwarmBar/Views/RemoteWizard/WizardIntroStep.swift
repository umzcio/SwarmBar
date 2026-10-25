import SwiftUI

/// Step 1: what this does. Nothing reaches out until "Look for hosts".
struct WizardIntroStep: View {
    let model: RemoteWizardModel
    let close: () -> Void

    var body: some View {
        WizardScaffold {
            Text("See agents running on other machines")
                .swarmFont(.title)
            Text("SwarmBar only reads this Mac. If you ssh into servers and run coding agents there, it can't see them yet.")
                .wizardMuted()
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    bullet("**Seeing sessions.** SwarmBar connects with your own ssh keys and config, and copies one small helper script to each host so it can read session state. No ports, no passwords, nothing stored.")
                    bullet("**Answering from the menu bar.** Approve, Deny and Reply work for remote sessions too. That needs a small hook added to each agent's config on the host, and you'll see every change before it's made.")
                    bullet("**Undo any time** from Settings › Hosts. Every file SwarmBar changes gets a backup first.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Spacer()
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
            Button("Look for hosts") {
                Task { await model.lookForHosts() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy)
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .swarmFont(.body)
    }
}
