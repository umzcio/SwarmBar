import SwiftUI

@main
struct SwarmBarApp: App {
    @State private var store: SessionStore

    init() {
        let store = SessionStore()
        _store = State(initialValue: store)
        Task { await MockSessionMonitor().start(into: store) }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environment(store)
        } label: {
            MenuBarLabel(
                anyActive: store.anyActive,
                attentionCount: store.attentionCount
            )
        }
        .menuBarExtraStyle(.window)
    }
}
