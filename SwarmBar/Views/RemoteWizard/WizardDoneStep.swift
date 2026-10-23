import SwiftUI

/// Step 4: every host this run watches, with its sessions as the store has
/// them right now and what this run's check found.
struct WizardDoneStep: View {
    let model: RemoteWizardModel
    let close: () -> Void

    var body: some View {
        let rows = model.watchedRows
        WizardScaffold {
            Text(verbatim: title(rows.count))
                .swarmFont(.title)
            if !rows.isEmpty {
                SettingsCard {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsDivider() }
                        WizardDoneRow(model: model, row: row)
                    }
                }
            }
            Text(rows.isEmpty
                 ? "Manage hosts in Settings › Hosts."
                 : "Their sessions are in the menu bar now. Manage hosts in Settings › Hosts.")
                .wizardMuted()
        } footer: {
            Spacer()
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func title(_ count: Int) -> String {
        if model.mode == .undo { return "Done" }
        return count == 0 ? "No hosts added" : "Watching \(WizardCopy.hosts(count))"
    }
}

private struct WizardDoneRow: View {
    @Environment(SessionStore.self) private var store
    let model: RemoteWizardModel
    let row: RemoteWizardModel.Row

    var body: some View {
        let name = model.watchedName(row.id)
        let pill = model.pill(for: row)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: name)
                .swarmFont(.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                headline(name, pill)
                    .swarmFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.notInTmuxLines(for: row.id), id: \.self) { line in
                    Text(verbatim: line)
                        .wizardMuted()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let pill {
                WizardPill(pill: pill, checkForReady: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    /// "5 sessions · approvals on", or "Just u · 2 sessions run as root and
    /// aren't shown", in the mockup's two shapes.
    private func headline(_ name: String, _ pill: RemoteWizardModel.Pill?) -> Text {
        if pill == .partial, let context = model.watchContext(for: row.id),
           let hidden = WizardCopy.hiddenLine(context) {
            return Text("\(Text(verbatim: "Just \(context.loginUser)").bold()) · \(hidden)")
        }
        return Text("\(Text(verbatim: sessions(name)).bold()) · \(status)")
    }

    /// From the store, which the host's monitor fills, so this is live.
    private func sessions(_ name: String) -> String {
        switch store.remoteReachability[name] {
        case nil, .connecting?:
            "Connecting…"
        case .unreachable?:
            "Can't reach this host right now"
        case .needsSetup(let message)?:
            message
        case .reachable?:
            WizardCopy.sessions(store.sessions.filter { $0.host == name }.count)
        }
    }

    private var status: String {
        if let problem = row.problem { return problem }
        switch row.assessment?.status {
        case .ready?: return "approvals on"
        case .needsSetup(let reasons)?: return reasons.first ?? "Needs setup"
        case .cantConnect(let problem)?: return problem.message
        case nil: return "Not checked"
        }
    }
}
