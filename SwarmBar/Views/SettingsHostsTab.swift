import SwiftUI

/// The words and pill on a Settings › Hosts row, kept out of the view so
/// every state is tested. Built from what the app already knows (the
/// registry, the store's rows and reachability) plus the last check the
/// user asked for, which may be missing.
enum HostRowText {
    enum Pill: Equatable {
        case ready, needsSetup, offline, partial, notChecked

        var label: String {
            switch self {
            case .ready: "Ready"
            case .needsSetup: "Needs setup"
            case .offline: "Offline"
            case .partial: "Partial"
            case .notChecked: "Not checked yet"
            }
        }
    }

    /// "5 sessions · every user · connected", "Unreachable for 4 min · rows
    /// kept", or "Just dev · 2 root sessions hidden". `sessions` counts the
    /// store's rows for this host. `loginUser` and `hiddenUsers` come from
    /// the last check, so before one the login user is "you" and nothing is
    /// said about hidden sessions: unknown is never "0 hidden".
    static func status(
        host: RemoteHost, reachability: RemoteReachability?, sessions: Int, assessment: HostAssessment?,
        loginUser: String? = nil, hiddenUsers: [String] = [], unreachableSince: Date? = nil,
        now: Date = .now
    ) -> String {
        guard host.isEnabled else { return "Not being watched" }
        switch reachability {
        case .unreachable?:
            let head = unreachableSince.map { "Unreachable for \(duration(from: $0, to: now))" } ?? "Unreachable"
            // The rows stay up while the host is away, which is worth saying
            // only when there are some.
            return sessions > 0 ? "\(head) · rows kept" : head
        case .needsSetup(let message)?:
            return message
        case .reachable?, .connecting?, nil:
            break
        }
        if case .cantConnect(let problem)? = assessment?.status { return problem.message }

        let count = sessions == 0 ? "No sessions" : WizardCopy.sessions(sessions)
        let scope = host.watchAs == .everyUser ? "every user" : "just \(loginUser ?? "you")"
        let parts: [String]
        if host.watchAs == .loginUser, let hidden = assessment?.hiddenSessions, hidden > 0 {
            parts = (sessions > 0 ? [count] : []) + [scope, hiddenPhrase(hidden, users: hiddenUsers)]
        } else {
            parts = [count, scope, reachability == .reachable ? "connected" : "connecting"]
        }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Reachability says Offline and Needs setup on its own. Ready and
    /// Partial need a check, and until there is one the host is not
    /// checked yet rather than assumed fine.
    static func pill(host: RemoteHost, reachability: RemoteReachability?, assessment: HostAssessment?) -> Pill {
        switch reachability {
        case .unreachable?: return .offline
        case .needsSetup?: return .needsSetup
        case .reachable?, .connecting?, nil: break
        }
        switch assessment?.status {
        case nil: return .notChecked
        case .cantConnect?: return .offline
        case .needsSetup?: return .needsSetup
        case .ready?: return (assessment?.hiddenSessions ?? 0) > 0 ? .partial : .ready
        }
    }

    /// Hooks hold Claude Code's and OpenCode's prompts and the Kimi family
    /// reads its own selector, so those are "approvals". Codex, Grok and
    /// Antigravity are answered by typing into the terminal.
    static func toggleTitle(_ tool: AgentTool) -> String {
        switch tool {
        case .codex, .grokBuild, .antigravity: "\(tool.label) keystroke answers"
        case .claudeCode, .kimiCode, .bearCode, .openCode: "\(tool.label) approvals"
        }
    }

    /// The tools a host has a switch for: any the last check found, any
    /// running in the latest snapshot, and any with a row. In AgentTool
    /// order, so the switches never shuffle between redraws.
    static func presentTools(
        checked: Set<AgentTool>?, processes: [RemoteProcessRecord], sessions: Set<AgentTool>
    ) -> [AgentTool] {
        var present = (checked ?? []).union(sessions)
        for process in processes {
            if let tool = ProbeResult.tool(forProcess: process.comm) { present.insert(tool) }
        }
        return AgentTool.allCases.filter(present.contains)
    }

    /// What an expanded row says in place of switches when there are none.
    /// A check that never connected looked at nothing, which must not read
    /// as a host with nothing on it.
    static func noToolsLine(check: RemoteMonitorSupervisor.HostCheck?) -> String {
        guard let check else { return "No agents seen on this host yet. Check all again to look." }
        if check.loginUser == nil { return "SwarmBar couldn't look at this host. Check all again to try." }
        return "No agents found on this host."
    }

    private static func hiddenPhrase(_ count: Int, users: [String]) -> String {
        if users.count == 1, let user = users.first {
            return count == 1 ? "1 \(user) session hidden" : "\(count) \(user) sessions hidden"
        }
        return count == 1 ? "1 session from another user hidden" : "\(count) sessions from other users hidden"
    }

    private static func duration(from start: Date, to now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(start) / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

// MARK: - The tab

/// Settings › Hosts: every configured remote host with its live state, its
/// per-tool switches, and the ways back into the wizard. Nothing here
/// reaches a host on its own; a host is only probed when the user presses
/// "Check all again".
struct HostsSettingsTab: View {
    @Environment(SessionStore.self) private var store
    @Environment(RemoteHostRegistry.self) private var registry: RemoteHostRegistry?
    @Environment(RemoteMonitorSupervisor.self) private var supervisor: RemoteMonitorSupervisor?
    @Environment(\.openRemoteWizard) private var openRemoteWizard
    @State private var expanded: UUID?

    var body: some View {
        if let registry, let supervisor {
            // Ticks so "Unreachable for 4 min" keeps counting while the
            // window is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    SettingsCardList {
                        if registry.hosts.isEmpty {
                            emptyState
                        } else {
                            hostList(registry, supervisor, now: context.date)
                            footer(supervisor)
                        }
                    }
                }
                // As tall as the list, up to a point, then it scrolls
                // rather than widening or growing the window off screen.
                .frame(maxHeight: 560)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            SettingsCardList {
                Text("Remote hosts aren't available in demo mode.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func hostList(
        _ registry: RemoteHostRegistry, _ supervisor: RemoteMonitorSupervisor, now: Date
    ) -> some View {
        SettingsCard {
            ForEach(Array(registry.hosts.enumerated()), id: \.element.id) { index, host in
                if index > 0 {
                    Divider().overlay(.white.opacity(0.06))
                }
                HostSettingsRow(
                    host: host, registry: registry, supervisor: supervisor, now: now,
                    isExpanded: expanded == host.id,
                    toggleExpanded: { expanded = expanded == host.id ? nil : host.id })
            }
        }
    }

    private func footer(_ supervisor: RemoteMonitorSupervisor) -> some View {
        HStack {
            Button("Add hosts…") { openRemoteWizard(.fresh) }
            Spacer()
            Button("Check all again") {
                Task { await supervisor.checkAllAgain() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .disabled(!supervisor.checking.isEmpty)
        }
        .padding(.top, 10)
    }

    private var emptyState: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("No remote hosts yet. Add hosts to see agents running on your servers.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add hosts…") { openRemoteWizard(.fresh) }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One host: name, status and pill, and when expanded the root sentence,
/// one switch per tool on the host, and the wizard's way back in.
private struct HostSettingsRow: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openRemoteWizard) private var openRemoteWizard
    let host: RemoteHost
    let registry: RemoteHostRegistry
    let supervisor: RemoteMonitorSupervisor
    let now: Date
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        let check = supervisor.checks[host.id]
        let sessions = store.sessions.filter { $0.host == host.displayName }
        let reachability = store.remoteReachability[host.displayName]
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(verbatim: host.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(minWidth: 84, alignment: .leading)
                        .fixedSize()
                    Text(verbatim: HostRowText.status(
                        host: host, reachability: reachability, sessions: sessions.count,
                        assessment: check?.assessment, loginUser: check?.loginUser,
                        hiddenUsers: check?.hiddenUsers ?? [],
                        unreachableSince: store.remoteUnreachableSince[host.displayName], now: now))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if supervisor.checking.contains(host.id) {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        HostPill(pill: HostRowText.pill(
                            host: host, reachability: reachability, assessment: check?.assessment))
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                details(check: check, sessions: sessions)
            }
        }
        .confirmationDialog(
            Text(verbatim: "Remove \(host.displayName)?"), isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { registry.remove(id: host.id) }
            Button("Undo changes first") { openWizard(.undo(alias: host.alias)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SwarmBar stops watching it. Its config changes stay until you undo them.")
        }
    }

    private func details(check: RemoteMonitorSupervisor.HostCheck?, sessions: [AgentSession]) -> some View {
        let tools = HostRowText.presentTools(
            checked: check?.tools, processes: snapshotProcesses, sessions: Set(sessions.map(\.tool)))
        return VStack(alignment: .leading, spacing: 0) {
            if host.watchAs == .everyUser {
                Text("SwarmBar reads every user's agent sessions on this host as root.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            if case .needsSetup(let reasons)? = check?.assessment.status {
                ForEach(reasons, id: \.self) { reason in
                    Text(verbatim: reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
            }
            if tools.isEmpty {
                Text(verbatim: HostRowText.noToolsLine(check: check))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            ForEach(tools) { tool in
                HStack {
                    // The switch carries the same title for VoiceOver, so
                    // this one is for the eye only.
                    Text(verbatim: HostRowText.toggleTitle(tool))
                        .font(.system(size: 12))
                        .accessibilityHidden(true)
                    Spacer(minLength: 12)
                    Toggle(HostRowText.toggleTitle(tool), isOn: approvals(tool))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(.orange)
                }
                .padding(.vertical, 3)
            }
            HStack(spacing: 6) {
                Button("Set up again") { openWizard(.setUp(alias: host.alias)) }
                Button("Undo changes…") { openWizard(.undo(alias: host.alias)) }
                Spacer()
                Button("Remove") { confirmingRemove = true }
            }
            .controlSize(.small)
            .padding(.top, 8)
        }
        .padding(.leading, 32)
        .padding(.trailing, 13)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            Divider().overlay(.white.opacity(0.06))
        }
    }

    /// The latest snapshot's agents, limited to the homes being watched, so
    /// a login-user host does not grow switches for root's agents.
    private var snapshotProcesses: [RemoteProcessRecord] {
        guard let snapshot = supervisor.connection(forHostID: host.id)?.lastSnapshot else { return [] }
        let users = Set(snapshot.homes.map(\.user))
        return snapshot.processes.filter { users.contains($0.user) }
    }

    /// On means approvals on, the opposite of what is stored. Written
    /// through the registry from its current copy, so a switch never puts
    /// back a stale host.
    private func approvals(_ tool: AgentTool) -> Binding<Bool> {
        Binding(
            get: { host.approvalsOn(for: tool) },
            set: { on in
                guard let current = registry.host(id: host.id) else { return }
                registry.upsert(current.settingApprovals(on, for: tool))
            })
    }

    /// The wizard is about to change this host, so the old verdict would
    /// outlive what it describes.
    private func openWizard(_ entry: RemoteWizardModel.Entry) {
        supervisor.forgetCheck(hostID: host.id)
        openRemoteWizard(entry)
    }
}

private struct HostPill: View {
    let pill: HostRowText.Pill

    var body: some View {
        Text(pill.label)
            .swarmFont(.captionEmphasis)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    private var tint: Color {
        switch pill {
        case .ready: .green
        case .needsSetup: .orange
        case .offline: .red
        case .partial: .blue
        case .notChecked: .gray
        }
    }
}
