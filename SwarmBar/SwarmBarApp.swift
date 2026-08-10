import SwiftUI

@main
struct SwarmBarApp: App {
    @State private var store: SessionStore
    private let hookServer: HookServer

    init() {
        let store = SessionStore()
        _store = State(initialValue: store)
        let hookServer = HookServer(store: store)
        self.hookServer = hookServer
        store.approvalResponder = hookServer
        hookServer.start()
        AgentNotifier.prepare()
        store.attentionAlertHandler = { session in
            let defaults = UserDefaults.standard
            let wantsIt: Bool
            let title: String
            if case .waitingApproval = session.status {
                wantsIt = (defaults.object(forKey: "notifyApprovals") as? Bool) ?? true
                title = "\(session.projectName) wants to run a command"
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
                sound: (defaults.object(forKey: "notifySound") as? Bool) ?? true
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
