import SwiftUI

/// The integrations panel, styled in the popover's own language rather
/// than stock Form chrome: one row per tool showing whether its approval
/// bridge is installed, with a toggle where there is something to
/// install. Monitors need nothing; this is only the approve/deny wiring.
struct SettingsView: View {
    @State private var manager = IntegrationManager()
    @AppStorage("grokKeystrokeAnswers") private var grokKeystrokes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("APPROVALS")
                .font(.subheadline.weight(.bold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(AgentTool.allCases.enumerated()), id: \.element) { index, tool in
                    if index > 0 {
                        Divider().padding(.leading, 52)
                    }
                    row(for: tool)
                }
            }
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 16)

            Text("Session monitoring works without any setup. These switches install each tool's approve and deny bridge; configs are backed up beside the original before the first change.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
        .frame(width: 430)
        .onAppear { manager.refresh() }
    }

    @ViewBuilder
    private func row(for tool: AgentTool) -> some View {
        let state = manager.states[tool] ?? .toolMissing
        HStack(spacing: 10) {
            ToolChip(tool: tool, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.label)
                    .font(.headline)
                Text(detailText(tool, state))
                    .font(.callout)
                    .foregroundStyle(stateStyle(state))
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            control(for: tool, state: state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func control(for tool: AgentTool, state: IntegrationManager.InstallState) -> some View {
        switch state {
        case .installed, .notInstalled, .failed:
            Toggle("", isOn: Binding(
                get: { state == .installed },
                set: { manager.setEnabled(tool, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(.orange)
        case .noSetupNeeded where tool == .grokBuild:
            Toggle("", isOn: $grokKeystrokes)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(.orange)
                .help("Off: Approve and Deny focus the terminal instead of answering the prompt remotely.")
        case .noSetupNeeded, .toolMissing:
            EmptyView()
        }
    }

    private func detailText(_ tool: AgentTool, _ state: IntegrationManager.InstallState) -> String {
        if tool == .grokBuild, state == .noSetupNeeded {
            return grokKeystrokes
                ? "Keystroke answers on"
                : "Focus-only: buttons open the terminal"
        }
        return state.label
    }

    private func stateStyle(_ state: IntegrationManager.InstallState) -> AnyShapeStyle {
        switch state {
        case .installed:     AnyShapeStyle(.green)
        case .failed:        AnyShapeStyle(.orange)
        default:             AnyShapeStyle(.secondary)
        }
    }
}
