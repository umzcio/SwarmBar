import SwiftUI

/// Step 2: hosts being checked, then the pick. The same rows throughout, so
/// each one stops its spinner as its own probe answers.
struct WizardPickStep: View {
    let model: RemoteWizardModel
    let back: () -> Void
    @State private var adding = false
    @State private var newAlias = ""
    @FocusState private var nameFocused: Bool

    private var checking: Bool { model.step == .checking }

    var body: some View {
        WizardScaffold {
            heading
            if !model.rows.isEmpty {
                SettingsCard {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsDivider() }
                        WizardHostRow(model: model, row: row, interactive: !checking)
                    }
                }
            } else if !checking {
                Text("No hosts found in ~/.ssh/config.")
                    .wizardMuted()
            }
            if model.step == .pick {
                addAndCheck
            }
            ForEach(model.configProblems, id: \.self) { problem in
                WizardNotice(text: problem)
            }
            if let skipped = model.skippedLine {
                Text(verbatim: skipped)
                    .wizardMuted()
            }
        } footer: {
            Button("Back", action: back)
            Spacer()
            Button(checking ? "Continue" : model.primaryTitle) {
                Task { await model.continueFromPick() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(checking || model.isProbing || model.isWorking)
        }
    }

    @ViewBuilder private var heading: some View {
        if checking {
            Text(verbatim: checkingTitle)
                .swarmFont(.title)
            Text("Read-only. Nothing is changed on any host.")
                .wizardMuted()
        } else {
            Text("Pick the hosts to watch")
                .swarmFont(.title)
            Text("Hosts with agents running are checked for you.")
                .wizardMuted()
        }
    }

    private var checkingTitle: String {
        if model.openedAtSetup, let row = model.rows.first { return "Checking \(row.displayName)" }
        if model.rows.isEmpty { return "Reading ~/.ssh/config" }
        return "Checking \(WizardCopy.hosts(model.rows.count)) from ~/.ssh/config"
    }

    private var addAndCheck: some View {
        HStack(spacing: 10) {
            if adding {
                TextField("Host name", text: $newAlias)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .focused($nameFocused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
                Button("Cancel") {
                    adding = false
                    newAlias = ""
                }
            } else {
                Button("+ Add a host by name…") {
                    adding = true
                    nameFocused = true
                }
                .buttonStyle(.link)
            }
            Spacer()
            Button("Check again") {
                Task { await model.checkAgain() }
            }
            .buttonStyle(.link)
            .disabled(model.isBusy)
        }
        .swarmFont(.body)
    }

    /// The typed name stays put when the add can't run yet, so nothing the
    /// user typed is lost to a check still in flight.
    private func add() {
        let alias = newAlias
        guard !alias.trimmingCharacters(in: .whitespaces).isEmpty, !model.isBusy, model.step == .pick else { return }
        adding = false
        newAlias = ""
        Task { await model.addHost(alias: alias) }
    }
}

/// One host: its check box, name, what the check found, and its pill.
private struct WizardHostRow: View {
    let model: RemoteWizardModel
    let row: RemoteWizardModel.Row
    /// False while hosts are first being checked, when nothing can be picked.
    let interactive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Watch \(row.displayName)", isOn: Binding(
                get: { row.isChecked },
                set: { model.setChecked(row.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!interactive || !RemoteWizardModel.canCheck(row))
            Text(verbatim: row.displayName)
                .swarmFont(.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 104, alignment: .leading)
            detail
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else if let pill = model.pill(for: row) {
                WizardPill(pill: pill)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 2) {
            if row.isChecking {
                Text("Connecting…")
                    .wizardMuted()
            } else if let problem = row.problem {
                Text(verbatim: problem)
                    .wizardMuted()
            } else if let assessment = row.assessment {
                switch assessment.status {
                case .cantConnect(let problem):
                    Text(verbatim: problem.message)
                        .wizardMuted()
                case .needsSetup(let reasons):
                    summary(assessment.summary)
                    Text(verbatim: reasons.joined(separator: "\n"))
                        .wizardMuted()
                case .ready:
                    summary(assessment.summary)
                    if model.pill(for: row) == .partial, let context = model.watchContext(for: row.id),
                       let hidden = WizardCopy.hiddenLine(context) {
                        Text(verbatim: "Just \(context.loginUser) · \(hidden)")
                            .wizardMuted()
                    }
                }
            }
        }
    }

    private func summary(_ text: String) -> some View {
        Text(verbatim: text)
            .swarmFont(text == HostAssessment.noAgents ? .body : .bodyEmphasis)
            .foregroundStyle(text == HostAssessment.noAgents ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
