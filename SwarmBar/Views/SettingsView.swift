import SwiftUI

/// The integrations panel. Two honest groups: bridges that install into a
/// tool's config, and capabilities that are built in. The switch carries
/// the state; the detail line says what the channel is, because a row
/// that needs its status written twice is a row that says nothing.
struct SettingsView: View {
    @State private var manager = IntegrationManager()

    private static let bridgeTools: [AgentTool] = [.claudeCode, .kimiCode, .bearCode, .openCode]
    private static let builtInTools: [AgentTool] = [.codex, .grokBuild]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)

            groupLabel("Approval bridges")
            card(tools: Self.bridgeTools)

            groupLabel("Built in")
                .padding(.top, 14)
            card(tools: Self.builtInTools)

            Text("Configs are backed up beside the original before the first change.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .frame(width: 440)
        .onAppear { manager.refresh() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: SwarmGlyphRenderer.solid())
                .renderingMode(.template)
                .resizable()
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("SwarmBar")
                    .font(.system(size: 15, weight: .bold))
                    .kerning(-0.2)
                Text("Approve and deny from the menu bar. Monitoring needs no setup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .kerning(0.7)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
    }

    private func card(tools: [AgentTool]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                if index > 0 {
                    Divider()
                        .overlay(.white.opacity(0.06))
                        .padding(.leading, 54)
                }
                IntegrationRow(tool: tool, manager: manager)
            }
        }
        .background(.white.opacity(0.045), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

private struct IntegrationRow: View {
    let tool: AgentTool
    let manager: IntegrationManager

    @AppStorage("grokKeystrokeAnswers") private var grokKeystrokes = true
    @State private var hovering = false

    var body: some View {
        let state = manager.states[tool] ?? .toolMissing
        HStack(spacing: 11) {
            ToolChip(tool: tool, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail(state))
                    .font(.system(size: 11.5))
                    .foregroundStyle(detailStyle(state))
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            control(state)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(hovering ? AnyShapeStyle(.white.opacity(0.03)) : AnyShapeStyle(.clear))
        .opacity(state == .toolMissing ? 0.45 : 1)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func control(_ state: IntegrationManager.InstallState) -> some View {
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
        case .noSetupNeeded:
            Text("Always on")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .toolMissing:
            EmptyView()
        }
    }

    /// What the channel is, not a restatement of the switch.
    private func detail(_ state: IntegrationManager.InstallState) -> String {
        if case .failed(let message) = state { return message }
        if state == .toolMissing { return "Not installed on this Mac" }
        switch tool {
        case .claudeCode: return "Hook bridge in settings.json, held decisions"
        case .kimiCode:   return "Hooks in config.toml, answers on screen"
        case .bearCode:   return "Hooks in config.toml, answers on screen"
        case .openCode:   return "Plugin inside the opencode server"
        case .codex:      return "Reads the session log, answers with hotkeys"
        case .grokBuild:
            return grokKeystrokes
                ? "Answers by typing into the terminal"
                : "Focus only: buttons open the terminal"
        }
    }

    private func detailStyle(_ state: IntegrationManager.InstallState) -> AnyShapeStyle {
        if case .failed = state { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.secondary)
    }
}
