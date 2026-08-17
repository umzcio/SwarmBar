import Foundation
import Testing
@testable import SwarmBar

@MainActor
@Suite("Session store host scoping")
struct SessionStoreHostScopeTests {
    private func session(id: UUID, host: String?) -> AgentSession {
        AgentSession(
            id: id, tool: .claudeCode, projectName: "demo",
            status: .working(activity: "thinking"), host: host
        )
    }

    @Test("a remote sync does not delete local sessions of the same tool")
    func remoteSyncKeepsLocal() {
        let store = SessionStore()
        let local = UUID(), remote = UUID()

        store.sync(tool: .claudeCode, host: nil, sessions: [session(id: local, host: nil)])
        store.sync(tool: .claudeCode, host: "umzcaio", sessions: [session(id: remote, host: "umzcaio")])

        #expect(store.sessions.contains { $0.id == local })
        #expect(store.sessions.contains { $0.id == remote })
    }

    @Test("a local sync does not delete another host's sessions")
    func localSyncKeepsRemote() {
        let store = SessionStore()
        let local = UUID(), remote = UUID()

        store.sync(tool: .claudeCode, host: "umzcaio", sessions: [session(id: remote, host: "umzcaio")])
        store.sync(tool: .claudeCode, host: nil, sessions: [session(id: local, host: nil)])

        #expect(store.sessions.contains { $0.id == remote })
        #expect(store.sessions.contains { $0.id == local })
    }

    @Test("a host's own sync still drops that host's vanished sessions")
    func hostSyncDropsItsOwn() {
        let store = SessionStore()
        let gone = UUID(), kept = UUID()

        store.sync(tool: .claudeCode, host: "umzcaio", sessions: [session(id: gone, host: "umzcaio")])
        store.sync(tool: .claudeCode, host: "umzcaio", sessions: [session(id: kept, host: "umzcaio")])

        #expect(!store.sessions.contains { $0.id == gone })
        #expect(store.sessions.contains { $0.id == kept })
    }

    // MARK: - openInTerminal gating (R1)
    //
    // TerminalFocuser.focus drives real AppleScript and pgrep calls, so its
    // side effect cannot be observed here. What can be tested, and is the
    // whole point of the fix, is the decision openInTerminal consults before
    // ever reaching TerminalFocuser: SessionStore.canOpenInTerminal. This is
    // the same rule the row views already apply to Open in Terminal and the
    // double click, now also enforced inside the store so a caller that is
    // not a view (the notification click handler in SwarmBarApp) cannot
    // bypass it and focus a terminal on this Mac for a session that is
    // actually running on another host.

    @Test("a remote session is not eligible to open a local terminal")
    func remoteSessionCannotOpenTerminal() {
        let remote = session(id: UUID(), host: "umzcaio")
        #expect(!SessionStore.canOpenInTerminal(remote))
    }

    @Test("a local session is still eligible to open a local terminal")
    func localSessionCanOpenTerminal() {
        let local = session(id: UUID(), host: nil)
        #expect(SessionStore.canOpenInTerminal(local))
    }
}
