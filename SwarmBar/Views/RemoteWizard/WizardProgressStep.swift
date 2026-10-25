import SwiftUI

/// Step 3 while SwarmBar makes the changes: each change with its outcome,
/// then the check that decides. A run that leaves the host not done goes
/// back to step 3, so this screen offers no write of its own.
struct WizardProgressStep: View {
    let model: RemoteWizardModel
    let index: Int
    let back: () -> Void

    var body: some View {
        if let alias = model.currentAlias, let row = model.rows.first(where: { $0.id == alias }) {
            content(alias, row)
        }
    }

    private func content(_ alias: String, _ row: RemoteWizardModel.Row) -> some View {
        WizardScaffold {
            WizardHeading(
                title: model.mode == .undo ? "Undoing changes on \(row.displayName)" : "Setting up \(row.displayName)",
                crumbs: "\(index + 1) of \(WizardCopy.hosts(model.setupAliases.count))")
            SettingsCard {
                WizardOutcomeList(
                    changes: (model.appliedPlan ?? model.plan(for: alias))?.changes ?? [],
                    progress: model.progress, isWorking: model.isWorking, hostName: row.displayName)
                    .padding(.vertical, 6)
            }
            Text("**If a file changed since SwarmBar read it**, that file is left alone and listed here with \"Changed on the host since it was checked. Check again to retry.\" Files already done stay done.")
                .swarmFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
        } footer: {
            if !model.isWorking {
                Button("Back", action: back)
            }
            Spacer()
            Button("Skip this host") { model.skipHost() }
                .disabled(model.isWorking)
            Button("Check again") { Task { await model.confirmPastedOrRan() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
        }
    }
}

/// A run's changes with their outcomes, and the check after it. Used while
/// the run goes, and under "Show what happened" on step 3 after it.
struct WizardOutcomeList: View {
    let changes: [PlannedChange]
    let progress: [Int: SetupApplier.StepOutcome]
    let isWorking: Bool
    let hostName: String

    var body: some View {
        let firstPending = changes.indices.first { progress[$0] == nil }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(changes.enumerated()), id: \.offset) { offset, change in
                line(change.description, progress[offset], running: isWorking && offset == firstPending)
            }
            checkLine(allReported: firstPending == nil)
        }
    }

    private func line(_ description: String, _ outcome: SetupApplier.StepOutcome?, running: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(outcome, running: running)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: description)
                    .swarmFont(.body)
                    .foregroundStyle(outcome == nil && !running ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(description), \(Self.state(outcome, running: running))")
                if let text = Self.outcomeText(outcome) {
                    Text(verbatim: text)
                        .wizardMuted()
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
    }

    /// The last line: the host checked again, which is what says Ready.
    private func checkLine(allReported: Bool) -> some View {
        let running = isWorking && allReported
        let finished = !isWorking && allReported
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if running {
                    ProgressView().controlSize(.mini)
                } else if finished {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)
            Text(verbatim: "Check \(hostName) again")
                .swarmFont(.body)
                .foregroundStyle(running || finished ? .primary : .secondary)
                .accessibilityLabel("Check \(hostName) again, \(running ? "running" : finished ? "done" : "waiting")")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
    }

    @ViewBuilder private func icon(_ outcome: SetupApplier.StepOutcome?, running: Bool) -> some View {
        switch outcome {
        case .done?:
            Image(systemName: "checkmark").foregroundStyle(.green)
        case .changed?:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed?:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .byHand?:
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
        case .skipped?:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case nil:
            if running {
                ProgressView().controlSize(.mini)
            } else {
                Text(verbatim: "·").foregroundStyle(.tertiary)
            }
        }
    }

    private static func outcomeText(_ outcome: SetupApplier.StepOutcome?) -> String? {
        switch outcome {
        case .changed?: "Changed on the host since it was checked. Check again to retry."
        case .failed(let message)?: "Failed: \(message)"
        case .byHand?: "By hand"
        case .skipped?: "Skipped"
        case .done?, nil: nil
        }
    }

    private static func state(_ outcome: SetupApplier.StepOutcome?, running: Bool) -> String {
        switch outcome {
        case .done?: "done"
        case .changed?: "changed on the host since it was checked. Check again to retry."
        case .failed(let message)?: "failed: \(message)"
        case .byHand?: "by hand"
        case .skipped?: "skipped"
        case nil: running ? "running" : "waiting"
        }
    }
}
