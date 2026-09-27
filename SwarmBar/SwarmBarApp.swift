import SwiftUI

@main
struct SwarmBarApp: App {
    @State private var store: SessionStore
    private let hookServer: HookServer

    init() {
        // A write to a pipe whose reader has already gone raises SIGPIPE,
        // and the default disposition kills the whole menu bar app. Every
        // child SwarmBar writes to can be gone by the time the write lands:
        // the remote helper install runs ssh and immediately pushes 9 KB
        // into its stdin, so a fast failure closes the read end first. With
        // the signal ignored the same case surfaces as EPIPE through the
        // throwing write, which every call site already handles.
        signal(SIGPIPE, SIG_IGN)

        let store = SessionStore()
        _store = State(initialValue: store)
        let hookServer = HookServer(store: store)
        self.hookServer = hookServer
        store.approvalResponder = hookServer
        hookServer.start()
        AgentNotifier.prepare()
        // Clicking a banner brings you to the session it is about. The
        // popover cannot be opened programmatically without reaching into
        // MenuBarExtra's private status item, and the terminal is where
        // the agent is waiting anyway.
        AgentNotifier.onClick = { [weak store] id in
            guard let session = store?.sessions.first(where: { $0.id == id }) else { return }
            store?.openInTerminal(session)
        }
        store.attentionAlertHandler = { session in
            let defaults = UserDefaults.standard
            let wantsIt: Bool
            let title: String
            if case .waitingApproval = session.status {
                wantsIt = (defaults.object(forKey: "notifyApprovals") as? Bool) ?? true
                // Not "wants to run a command": AskUserQuestion also arrives
                // through the permission hook, with the question as the body.
                title = "\(session.projectName) needs your approval"
            } else {
                wantsIt = (defaults.object(forKey: "notifyWaiting") as? Bool) ?? false
                title = "\(session.projectName) is waiting on you"
            }
            guard wantsIt else { return }
            let body: String
            switch session.status {
            case .waitingApproval(let command): body = command
            case .waitingInput(let prompt): body = prompt.isEmpty ? session.tool.label : prompt
            default: return
            }
            AgentNotifier.post(
                title: title,
                body: body,
                sound: (defaults.object(forKey: "notifySound") as? Bool) ?? true,
                sessionID: session.id
            )
        }
        store.idleTurnHandler = { session in
            let defaults = UserDefaults.standard
            guard (defaults.object(forKey: "notifyWaiting") as? Bool) ?? false,
                  case .done(let summary) = session.status else { return }
            AgentNotifier.post(
                title: "\(session.projectName) is waiting on you",
                body: summary.isEmpty ? session.tool.label : summary,
                sound: (defaults.object(forKey: "notifySound") as? Bool) ?? true,
                sessionID: session.id
            )
        }
        // Real monitors by default; --mock replays the prototype simulation
        // so the demo mode survives.
        if CommandLine.arguments.contains("--mock") {
            Task { await MockSessionMonitor().start(into: store) }
        } else {
            Task { await ClaudeCodeMonitor().start(into: store) }
            Task { await CodexMonitor().start(into: store) }
            Task { await KimiMonitor().start(into: store) }
            Task { await KimiMonitor.BearCode().start(into: store) }
            Task { await OpenCodeMonitor().start(into: store) }
            Task { await GrokBuildMonitor().start(into: store) }
            Task { await AntigravityMonitor().start(into: store) }
            for host in RemoteHostStore.load(from: .standard) where host.isEnabled {
                Task { await RemoteHostMonitor(host: host).start(into: store) }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
