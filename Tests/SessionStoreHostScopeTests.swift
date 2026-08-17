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
}
