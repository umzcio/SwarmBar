import SwiftUI

/// The integrations panel: one row per tool showing whether its approval
/// bridge is installed, with a toggle where there is something to
/// install. Monitors need nothing; this is only the approve/deny wiring.
struct SettingsView: View {
    @State private var manager = IntegrationManager()
    @AppStorage("grokKeystrokeAnswers") private var grokKeystrokes = true

    var body: some View {
        Form {
            Section {
                ForEach(AgentTool.allCases) { tool in
                    row(for: tool)
                }
            } header: {
                Text("Approvals")
            } footer: {
                Text("Session monitoring works without any setup. These switches install each tool's approve and deny bridge; configs are backed up beside the original before the first change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { manager.refresh() }
    }

    @ViewBuilder
    private func row(for tool: AgentTool) -> some View {
        let state = manager.states[tool] ?? .toolMissing
        HStack(spacing: 10) {
            ToolChip(tool: tool, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.label)
                    .font(.body.weight(.medium))
                Text(state.label)
                    .font(.callout)
                    .foregroundStyle(stateStyle(state))
            }
            Spacer()
            switch state {
            case .installed, .notInstalled, .failed:
                Toggle("", isOn: Binding(
                    get: { state == .installed },
                    set: { manager.setEnabled(tool, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            case .noSetupNeeded where tool == .grokBuild:
                Toggle("Keystroke answers", isOn: $grokKeystrokes)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Off: Approve and Deny just focus the terminal instead of answering the prompt remotely.")
            case .noSetupNeeded, .toolMissing:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private func stateStyle(_ state: IntegrationManager.InstallState) -> AnyShapeStyle {
        switch state {
        case .installed:     AnyShapeStyle(.green)
        case .failed:        AnyShapeStyle(.orange)
        default:             AnyShapeStyle(.secondary)
        }
    }
}
