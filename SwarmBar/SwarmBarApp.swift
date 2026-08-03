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
        // Real monitors by default; --mock replays the prototype simulation
        // so the demo mode survives.
        if CommandLine.arguments.contains("--mock") {
            Task { await MockSessionMonitor().start(into: store) }
        } else {
            Task { await ClaudeCodeMonitor().start(into: store) }
            Task { await CodexMonitor().start(into: store) }
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
    }
}
