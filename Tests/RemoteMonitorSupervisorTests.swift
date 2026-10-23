import Foundation
import Testing
@testable import SwarmBar

@MainActor
private final class MonitorLog {
    var started: [UUID] = []
    var cancelled: [UUID] = []
}

private struct FakeMonitor: SessionMonitor {
    let id: UUID
    let log: MonitorLog

    func start(into store: SessionStore) async {
        await MainActor.run { log.started.append(id) }
        try? await Task.sleep(for: .seconds(3600))
        await MainActor.run { log.cancelled.append(id) }
    }
}

@MainActor
@Suite("Remote monitor supervisor")
struct RemoteMonitorSupervisorTests {
    @MainActor final class FactoryCounter { var count = 0 }

    @MainActor private final class Rig {
        let store: SessionStore
        let registry: RemoteHostRegistry
        let log: MonitorLog
        let factoryCalls: FactoryCounter
        let supervisor: RemoteMonitorSupervisor

        init() {
            let log = MonitorLog()
            let counter = FactoryCounter()
            let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
            let registry = RemoteHostRegistry(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
            self.store = store
            self.registry = registry
            self.log = log
            self.factoryCalls = counter
            supervisor = RemoteMonitorSupervisor(store: store, registry: registry) { host in
                counter.count += 1
                return FakeMonitor(id: host.id, log: log)
            }
        }
    }

    /// Polls for the expected condition instead of sleeping a fixed time.
    private func settle(timeout: Duration = .seconds(2), until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func session(host: String?) -> AgentSession {
        AgentSession(tool: .claudeCode, projectName: "demo",
                     status: .working(activity: "thinking"), host: host)
    }

    private func wire(_ rig: Rig) {
        rig.registry.onChange = { [supervisor = rig.supervisor] in supervisor.reconcile() }
    }

    /// Seeds a running host with a row and a reachability entry.
    private func seedRunning(_ rig: Rig, _ host: RemoteHost) async {
        wire(rig)
        rig.registry.upsert(host)
        await settle { rig.log.started.contains(host.id) }
        rig.store.sync(tool: .claudeCode, host: host.displayName, sessions: [session(host: host.displayName)])
        rig.store.noteRemoteReachability(host: host.displayName, .unreachable("down"))
    }

    @Test func noHostsStartsNothing() async {
        let rig = Rig()
        rig.supervisor.reconcile()
        await settle(timeout: .milliseconds(100)) { false }
        #expect(rig.supervisor.runningHostIDs.isEmpty)
        #expect(rig.factoryCalls.count == 0)
    }

    @Test func enabledHostStarts() async {
        let rig = Rig()
        let host = RemoteHost(alias: "devbox")
        wire(rig)
        rig.registry.upsert(host)
        await settle { rig.log.started.contains(host.id) }
        #expect(rig.supervisor.runningHostIDs == [host.id])
        #expect(rig.log.started == [host.id])
    }

    @Test func disabledHostDoesNotStart() async {
        let rig = Rig()
        rig.registry.upsert(RemoteHost(alias: "devbox", isEnabled: false))
        rig.supervisor.reconcile()
        await settle(timeout: .milliseconds(100)) { false }
        #expect(rig.supervisor.runningHostIDs.isEmpty)
        #expect(rig.factoryCalls.count == 0)
    }

    @Test func removingHostCancelsAndClearsRows() async {
        let rig = Rig()
        let host = RemoteHost(alias: "devbox", displayName: "devbox")
        await seedRunning(rig, host)
        #expect(rig.store.sessions.contains { $0.host == "devbox" })

        rig.registry.remove(id: host.id)
        await settle { rig.log.cancelled.contains(host.id) }
        #expect(rig.supervisor.runningHostIDs.isEmpty)
        #expect(!rig.store.sessions.contains { $0.host == "devbox" })
        #expect(rig.store.remoteReachability["devbox"] == nil)
        #expect(rig.log.cancelled == [host.id])
    }

    @Test func disablingRunningHostClearsRows() async {
        let rig = Rig()
        var host = RemoteHost(alias: "devbox", displayName: "devbox")
        await seedRunning(rig, host)
        host.isEnabled = false
        rig.registry.upsert(host)
        await settle { rig.log.cancelled.contains(host.id) }
        #expect(rig.supervisor.runningHostIDs.isEmpty)
        #expect(!rig.store.sessions.contains { $0.host == "devbox" })
        #expect(rig.store.remoteReachability["devbox"] == nil)
    }

    @Test func disableThenRemoveLeavesNothing() async {
        let rig = Rig()
        var host = RemoteHost(alias: "devbox", displayName: "devbox")
        await seedRunning(rig, host)
        host.isEnabled = false
        rig.registry.upsert(host)
        rig.registry.remove(id: host.id)
        await settle { rig.log.cancelled.contains(host.id) }
        #expect(rig.store.sessions.isEmpty)
        #expect(rig.store.remoteReachability["devbox"] == nil)
    }

    @Test func aliasChangeRestarts() async {
        let rig = Rig()
        var host = RemoteHost(alias: "devbox", displayName: "devbox")
        await seedRunning(rig, host)
        host.alias = "devbox2"
        rig.registry.upsert(host)
        await settle { rig.log.started.count == 2 && rig.log.cancelled.count == 1 }
        #expect(rig.factoryCalls.count == 2)
        #expect(rig.log.started == [host.id, host.id])
        #expect(rig.log.cancelled == [host.id])
        #expect(rig.supervisor.runningHostIDs == [host.id])
        #expect(!rig.store.sessions.contains { $0.host == "devbox" })
        #expect(rig.store.remoteReachability["devbox"] == nil)
    }

    @Test func displayNameChangeRestartsAndClearsOldName() async {
        let rig = Rig()
        var host = RemoteHost(alias: "devbox", displayName: "old")
        await seedRunning(rig, host)
        host.displayName = "new"
        rig.registry.upsert(host)
        await settle { rig.log.started.count == 2 && rig.log.cancelled.count == 1 }
        #expect(rig.factoryCalls.count == 2)
        #expect(!rig.store.sessions.contains { $0.host == "old" })
        #expect(rig.store.remoteReachability["old"] == nil)
    }

    @Test func approvalsOffChangeDoesNotRestart() async {
        let rig = Rig()
        var host = RemoteHost(alias: "devbox")
        wire(rig)
        rig.registry.upsert(host)
        await settle { rig.log.started.contains(host.id) }
        host.approvalsOff = [.codex]
        rig.registry.upsert(host)
        await settle(timeout: .milliseconds(100)) { false }
        #expect(rig.factoryCalls.count == 1)
        #expect(rig.log.cancelled.isEmpty)
    }

    @Test func clearHostLeavesOtherHostsAndLocalRows() {
        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let local = session(host: nil), a = session(host: "alpha"), b = session(host: "beta")
        store.sync(tool: .claudeCode, host: nil, sessions: [local])
        store.sync(tool: .claudeCode, host: "alpha", sessions: [a])
        store.sync(tool: .claudeCode, host: "beta", sessions: [b])
        store.noteRemoteReachability(host: "alpha", .unreachable("down"))
        store.noteRemoteReachability(host: "beta", .unreachable("down"))

        store.clearHost("alpha")
        #expect(Set(store.sessions.map(\.id)) == [local.id, b.id])
        #expect(store.remoteReachability["alpha"] == nil)
        #expect(store.remoteReachability["beta"] != nil)
    }
}
