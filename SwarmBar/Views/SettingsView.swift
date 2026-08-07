import ServiceManagement
import SwiftUI

/// Settings in the System Settings idiom: toolbar tabs for General
/// (behavior), Providers (per-tool approval wiring), and Notifications
/// (alerts when an agent needs you).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettingsTab()
                .tabItem { Label("Providers", systemImage: "circle.hexagongrid") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
        }
        .frame(width: 440)
        .background(
            // Esc closes the window, as it should for a utility panel.
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("compactRows") private var compactRows = false
    @AppStorage("popoverScale") private var popoverScale = PopoverScale.medium.rawValue
    @AppStorage("doubleClickOpensTerminal") private var doubleClickOpensTerminal = true
    @State private var updates = UpdateChecker()

    var body: some View {
        SettingsCardList {
            SettingsCard {
                HStack(spacing: 11) {
                    Image(nsImage: SwarmGlyphRenderer.solid())
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                        .padding(1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SwarmBar")
                            .font(.system(size: 13, weight: .semibold))
                        Text(versionLine)
                            .font(.system(size: 11.5))
                            .foregroundStyle(versionStyle)
                    }
                    Spacer(minLength: 12)
                    if case .available(_, let url) = updates.status {
                        Button("View release") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                    } else {
                        Button("Check for updates") { updates.check() }
                            .controlSize(.small)
                            .disabled(updates.status == .checking)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
            }
            .padding(.bottom, 12)

            SettingsCard {
                SettingsToggleRow(
                    symbol: "power",
                    title: "Launch at login",
                    detail: "Start SwarmBar when you sign in",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, enable in
                    do {
                        if enable {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "rectangle.compress.vertical",
                    title: "Compact rows",
                    detail: "Single-line sessions in the popover",
                    isOn: $compactRows
                )
                SettingsDivider()
                SettingsPickerRow(
                    symbol: "textformat.size",
                    title: "Text size",
                    detail: "Scales the whole popover, not just the text"
                ) {
                    Picker("", selection: $popoverScale) {
                        ForEach(PopoverScale.allCases) { scale in
                            Text(scale.label).tag(scale.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 168)
                }
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "cursorarrow.click.2",
                    title: "Double-click opens Terminal",
                    detail: "Jump to a session's terminal from its row",
                    isOn: $doubleClickOpensTerminal
                )
            }
        }
    }

    private var versionLine: String {
        let base = "Version \(UpdateChecker.currentVersion) (\(UpdateChecker.currentBuild))"
        switch updates.status {
        case .idle:                     return base
        case .checking:                 return "Checking for updates…"
        case .upToDate:                 return "\(base) · Up to date"
        case .available(let v, _):      return "\(base) · \(v) available"
        case .failed(let message):      return "\(base) · \(message)"
        }
    }

    private var versionStyle: AnyShapeStyle {
        if case .available = updates.status { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.secondary)
    }
}

// MARK: - Providers

struct ProvidersSettingsTab: View {
    @Environment(SessionStore.self) private var store
    @State private var manager = IntegrationManager()

    private static let bridgeTools: [AgentTool] = [.claudeCode, .kimiCode, .bearCode, .openCode]
    private static let builtInTools: [AgentTool] = [.codex, .grokBuild]

    var body: some View {
        SettingsCardList {
            SettingsCard {
                HStack(spacing: 11) {
                    Image(systemName: bridgeSymbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(bridgeTint)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hook bridge")
                            .font(.system(size: 13, weight: .semibold))
                        Text(bridgeDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
            }
            .padding(.bottom, 12)

            SettingsGroupLabel("Approval bridges")
            SettingsCard {
                ForEach(Array(Self.bridgeTools.enumerated()), id: \.element) { index, tool in
                    if index > 0 { SettingsDivider() }
                    IntegrationRow(tool: tool, manager: manager)
                }
            }

            SettingsGroupLabel("Built in")
                .padding(.top, 12)
            SettingsCard {
                ForEach(Array(Self.builtInTools.enumerated()), id: \.element) { index, tool in
                    if index > 0 { SettingsDivider() }
                    IntegrationRow(tool: tool, manager: manager)
                }
            }

            Text("Configs are backed up beside the original before the first change.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.top, 10)
        }
        .onAppear { manager.refresh() }
    }

    private var bridgeSymbol: String {
        if case .listening = store.hookServerState { return "antenna.radiowaves.left.and.right" }
        return "exclamationmark.triangle"
    }

    private var bridgeTint: Color {
        if case .listening = store.hookServerState { return .secondary }
        return .orange
    }

    private var bridgeDetail: String {
        switch store.hookServerState {
        case .starting:    "Starting up"
        case .listening:   "Listening on 127.0.0.1:\(HookServer.port)"
        case .unavailable(let reason):
            "Not listening, so remote approve and deny will not reach your agents. \(reason)"
        }
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

// MARK: - Notifications

struct NotificationSettingsTab: View {
    @AppStorage("notifyApprovals") private var notifyApprovals = true
    @AppStorage("notifyWaiting") private var notifyWaiting = false
    @AppStorage("notifySound") private var notifySound = true

    var body: some View {
        SettingsCardList {
            SettingsCard {
                SettingsToggleRow(
                    symbol: "exclamationmark.circle",
                    symbolTint: .orange,
                    title: "Approval requests",
                    detail: "Notify when an agent asks permission",
                    isOn: $notifyApprovals
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "bubble.left",
                    symbolTint: .blue,
                    title: "Waiting on you",
                    detail: "Notify when an agent asks a question",
                    isOn: $notifyWaiting
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "speaker.wave.2",
                    title: "Sound",
                    detail: "Play the alert sound with notifications",
                    isOn: $notifySound
                )
            }

            Text("A session posts once when it starts needing you, not on every poll.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.top, 10)
        }
    }
}

// MARK: - Shared pieces

private struct SettingsCardList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.white.opacity(0.045), in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct SettingsGroupLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .kerning(0.7)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(.white.opacity(0.06))
            .padding(.leading, 54)
    }
}

/// Same shape as `SettingsToggleRow`, with an arbitrary control on the
/// trailing edge instead of a switch.
private struct SettingsPickerRow<Control: View>: View {
    let symbol: String
    var symbolTint: Color = .secondary
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(symbolTint)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }
}

private struct SettingsToggleRow: View {
    let symbol: String
    var symbolTint: Color = .secondary
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(symbolTint)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(.orange)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }
}
