import Foundation
import Testing
@testable import SwarmBar

private let pythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// Polls for the expected condition instead of sleeping a fixed time.
@MainActor
private func settle(timeout: Duration = .seconds(15), until condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// A fresh temp directory for one test, removed by the test when it ends.
private func freshBase(_ label: String) throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// A stand-in helper that answers `ping` with `pingReply` (a python dict
/// literal) and `snapshot` with a valid, empty protocol 3 snapshot, whose
/// process list failed when `processesFailed` says so. Its
/// hash never matches the bundled helper's unless `pingReply` says so.
private func scriptedHelper(in base: URL, pingReply: String, processesFailed: Bool = false) throws -> HelperLaunch {
    let source = """
    import json, sys, time
    for line in sys.stdin:
        request = json.loads(line)
        command = request.get("cmd")
        if command == "ping":
            reply = \(pingReply)
        elif command == "snapshot":
            reply = {"ok": True, "protocol": 3, "stream": "old-helper", "hostname": "devbox",
                     "system": "Linux", "now": time.time(), "homes": [], "files": [], "dirs": [],
                     "omitted": [], "warnings": [], "processes": [], "processes_failed": \(processesFailed ? "True" : "False")}
        else:
            reply = {"ok": False, "error": "unknown command"}
        reply["id"] = request["id"]
        print(json.dumps(reply), flush=True)
    """
    let path = base.appendingPathComponent("scripted-helper.py").path
    try source.write(toFile: path, atomically: true, encoding: .utf8)
    return .local(python: "/usr/bin/python3", script: path, homes: [])
}

private let stalePing = #"{"ok": True, "protocol": 3, "sha256": "0" * 64, "stream": "old-helper"}"#

/// Records whether an install was attempted, from inside a `@Sendable`
/// runner.
private actor InstallLog {
    var calls = 0
    func note() { calls += 1 }
}

/// One synthetic host: a temp home holding Claude transcripts, a private
/// copy of the bundled helper run locally against it, and a mirror under
/// the same temp directory. The copy lets a test take the helper away to
/// make the next launch fail.
@MainActor
private final class MonitorRig {
    static let first = UUID(uuidString: "6f1c2a44-0b7e-4d0e-9a51-3c2d8e7f9a10")!
    static let second = UUID(uuidString: "2b7e1d90-4c3a-4f5e-8d6c-7a8b9c0d1e2f")!

    let base: URL
    let home: URL
    let script: URL
    let host: RemoteHost
    let connection: RemoteHostConnection
    let store: SessionStore
    private var task: Task<Void, Never>?

    private let installRunner: HelperInstaller.Runner?

    init(watchAs: WatchAs = .loginUser, launch: ((URL) throws -> HelperLaunch)? = nil,
         installRunner: HelperInstaller.Runner? = nil) throws {
        let base = try freshBase("remote-monitor")
        let home = base.appendingPathComponent("home/u")
        let script = base.appendingPathComponent("helper/swarmbar-helper.py")
        let helper: HelperLaunch
        do {
            for id in [Self.first, Self.second] {
                try Self.writeTranscript(id, in: home)
            }
            let bundled = try #require(Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"))
            try FileManager.default.createDirectory(
                at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled, to: script)
            helper = try launch?(base)
                ?? .local(python: "/usr/bin/python3", script: script.path, homes: [home.path])
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
        self.base = base
        self.home = home
        self.script = script
        self.installRunner = installRunner
        host = RemoteHost(alias: "devbox", displayName: "devbox", watchAs: watchAs)
        connection = RemoteHostConnection(
            host: host, channel: SSHChannel(launch: helper),
            mirror: RemoteMirror(root: base.appendingPathComponent("mirror")))
        store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
    }

    static func writeTranscript(_ id: UUID, in home: URL) throws {
        let url = transcript(id, in: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture("claude-working").write(to: url, atomically: true, encoding: .utf8)
    }

    static func transcript(_ id: UUID, in home: URL) -> URL {
        home.appendingPathComponent(".claude/projects/-home-u-demo/\(id.uuidString.lowercased()).jsonl")
    }

    func start() {
        let monitor = RemoteHostMonitor(
            connection: connection, pollInterval: .milliseconds(100), installRunner: installRunner)
        let store = store
        task = Task { await monitor.start(into: store) }
    }

    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    var rows: [AgentSession] { store.sessions.filter { $0.host == "devbox" } }

    func rowID(_ local: UUID) -> UUID {
        RemoteIdentity.sessionID(hostID: host.id, home: home.path, localID: local)
    }
}

@MainActor
@Suite("Remote host monitor")
struct RemoteHostMonitorTests {
    @Test("a reinstall is skipped while backoff is still below the cap")
    func belowCapSkipsReinstall() {
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 1) == false)
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 8) == false)
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 59) == false)
    }

    @Test("a reinstall fires once backoff reaches the cap")
    func atCapReinstalls() {
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 60) == true)
    }

    @Test("a reinstall keeps firing above the cap")
    func aboveCapReinstalls() {
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 61) == true)
        #expect(RemoteHostMonitor.shouldReinstall(afterBackoff: 999) == true)
    }

    @Test("the install wait is bounded, and by less than one poll's worth of stalling")
    func installWaitIsBounded() {
        // The point of the bound is that a half-open connection cannot wedge
        // a host's loop before its do/catch, where nothing updates
        // reachability. It has to outlast a connect (10s) and be short
        // enough that the host recovers on its own.
        #expect(HelperInstaller.installTimeout > 10)
        #expect(HelperInstaller.installTimeout <= 60)
    }

    @Test("one poll syncs the host's rows and marks it reachable", .enabled(if: pythonAvailable))
    func onePollProducesRows() async throws {
        let rig = try MonitorRig()
        defer { rig.remove() }
        rig.start()
        await settle { rig.rows.count == 2 && rig.store.remoteReachability["devbox"] == .reachable }
        await rig.stop()

        #expect(Set(rig.rows.map(\.id)) == [rig.rowID(MonitorRig.first), rig.rowID(MonitorRig.second)])
        #expect(rig.rows.allSatisfy { $0.tool == .claudeCode })
        #expect(rig.store.remoteReachability["devbox"] == .reachable)
        #expect(rig.connection.lastSnapshot != nil)
        // The mirror holds the host's files at their own paths.
        let mirrored = try #require(rig.connection.mirror.local(
            MonitorRig.transcript(MonitorRig.first, in: rig.home).path))
        #expect(FileManager.default.fileExists(atPath: mirrored.path))
    }

    @Test("a failed poll keeps the rows and says the host is unreachable", .enabled(if: pythonAvailable))
    func failedPollKeepsRows() async throws {
        let rig = try MonitorRig()
        defer { rig.remove() }
        rig.start()
        await settle { rig.rows.count == 2 && rig.store.remoteReachability["devbox"] == .reachable }
        let before = rig.rows
        #expect(before.count == 2)

        // The helper goes away and the running one is stopped, so the next
        // launch fails the way a host that has gone dark does.
        try FileManager.default.removeItem(at: rig.script)
        await rig.connection.channel.shutdown()
        await settle {
            if case .unreachable = rig.store.remoteReachability["devbox"] { return true }
            return false
        }
        await rig.stop()

        guard case .unreachable = rig.store.remoteReachability["devbox"] else {
            Issue.record("expected unreachable, got \(String(describing: rig.store.remoteReachability["devbox"]))")
            return
        }
        #expect(rig.rows.map(\.id) == before.map(\.id))
        #expect(rig.rows.map(\.status) == before.map(\.status))
    }

    @Test("a restarted helper resets the mirror", .enabled(if: pythonAvailable))
    func restartedHelperResetsMirror() async throws {
        let rig = try MonitorRig()
        defer { rig.remove() }
        rig.start()
        await settle { rig.rows.count == 2 }
        #expect(rig.rows.count == 2)

        // Something only a reset removes: it sits outside every home, so
        // the per-home sweep never reaches it.
        let stray = rig.connection.mirror.root.appendingPathComponent("stray")
        try Data("stray".utf8).write(to: stray)
        let shipped = try #require(rig.connection.lastSnapshot)
        await settle { rig.connection.lastSnapshot?.now != shipped.now }
        #expect(rig.connection.lastSnapshot?.stream == shipped.stream)
        #expect(FileManager.default.fileExists(atPath: stray.path), "a poll on the same stream kept it")

        // During the gap a session goes away on the host.
        let gone = MonitorRig.transcript(MonitorRig.second, in: rig.home)
        try FileManager.default.removeItem(at: gone)
        await rig.connection.channel.shutdown()
        await settle { rig.connection.lastSnapshot?.stream != shipped.stream && rig.rows.count == 1 }
        await rig.stop()

        #expect(rig.connection.lastSnapshot?.stream != shipped.stream)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        let mirrored = try #require(rig.connection.mirror.local(gone.path))
        #expect(!FileManager.default.fileExists(atPath: mirrored.path))
        #expect(rig.rows.map(\.id) == [rig.rowID(MonitorRig.first)])
    }

    @Test("removing a host deletes its mirror", .enabled(if: pythonAvailable))
    func removingHostDeletesItsMirror() async throws {
        let base = try freshBase("remote-supervisor")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home/u")
        try MonitorRig.writeTranscript(MonitorRig.first, in: home)
        let script = try #require(Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"))
        let mirrorRoot = base.appendingPathComponent("mirror")

        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let registry = RemoteHostRegistry(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let supervisor = RemoteMonitorSupervisor(store: store, registry: registry) { host in
            let connection = RemoteHostConnection(
                host: host,
                channel: SSHChannel(launch: .local(
                    python: "/usr/bin/python3", script: script.path, homes: [home.path])),
                mirror: RemoteMirror(root: mirrorRoot))
            return (RemoteHostMonitor(connection: connection, pollInterval: .milliseconds(100)), connection)
        }
        registry.onChange = { [supervisor] in supervisor.reconcile() }

        let host = RemoteHost(alias: "devbox", displayName: "devbox")
        registry.upsert(host)
        #expect(supervisor.connection(forHostID: host.id)?.host == host)
        #expect(supervisor.connection(forHostName: "devbox")?.host == host)
        await settle { store.sessions.contains { $0.host == "devbox" } }
        #expect(FileManager.default.fileExists(atPath: mirrorRoot.path))

        registry.remove(id: host.id)
        #expect(supervisor.connection(forHostID: host.id) == nil)
        #expect(supervisor.connection(forHostName: "devbox") == nil)
        await settle { !FileManager.default.fileExists(atPath: mirrorRoot.path) }
        #expect(!FileManager.default.fileExists(atPath: mirrorRoot.path))
        #expect(!store.sessions.contains { $0.host == "devbox" })
    }

    @Test("a tool the pass cannot vouch for keeps its rows", .enabled(if: pythonAvailable))
    func unverifiedToolsKeepTheirRows() async throws {
        let rig = try MonitorRig(launch: {
            try scriptedHelper(in: $0, pingReply: stalePing, processesFailed: true)
        })
        defer { rig.remove() }
        let kept = AgentSession(
            tool: .codex, projectName: "demo", status: .working(activity: "thinking"), host: "devbox")
        rig.store.sync(tool: .codex, host: "devbox", sessions: [kept])
        rig.start()
        await settle { rig.connection.lastSnapshot != nil && rig.store.remoteReachability["devbox"] == .reachable }
        await rig.stop()

        // A failed process list leaves every tool unverified, so an empty
        // result must not read as "nothing running there".
        #expect(rig.connection.lastSnapshot?.processesFailed == true)
        #expect(rig.rows.map(\.id) == [kept.id])
    }

    @Test("a helper sudo will not update keeps polling and asks for setup", .enabled(if: pythonAvailable))
    func staleHelperNeedingSudoKeepsPolling() async throws {
        let rig = try MonitorRig(
            watchAs: .everyUser,
            launch: { try scriptedHelper(in: $0, pingReply: stalePing) },
            installRunner: { _, _, _ in
                throw HelperInstaller.InstallFailure(
                    message: "helper install exited 1: sudo: a password is required",
                    stderr: "sudo: a password is required\n")
            })
        defer { rig.remove() }
        rig.start()
        await settle { rig.connection.lastSnapshot != nil }
        await rig.stop()

        #expect(rig.connection.lastSnapshot?.stream == "old-helper")
        #expect(rig.store.remoteReachability["devbox"] == .needsSetup(HelperInstaller.updateNeedsSetupMessage))
        #expect(HelperInstaller.updateNeedsSetupMessage
            == "SwarmBar was updated. Run the setup command again to update its helper.")
    }
}

@Suite("Helper installer")
struct HelperInstallerTests {
    @Test("a local helper whose hash matches is left alone", .enabled(if: pythonAvailable))
    func matchingLocalHelperIsCurrent() async throws {
        let base = try freshBase("helper-installer")
        defer { try? FileManager.default.removeItem(at: base) }
        let script = try #require(Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"))
        let channel = SSHChannel(launch: .local(python: "/usr/bin/python3", script: script.path, homes: [base.path]))
        let log = InstallLog()
        let outcome = await HelperInstaller.ensureInstalled(
            alias: "devbox", watchAs: .everyUser, channel: channel,
            runner: { _, _, _ in await log.note() })
        await channel.shutdown()
        #expect(outcome == .current)
        #expect(await log.calls == 0)
    }

    @Test("a stale helper is pushed and the channel restarted", .enabled(if: pythonAvailable))
    func staleHelperIsPushed() async throws {
        let base = try freshBase("helper-installer")
        defer { try? FileManager.default.removeItem(at: base) }
        let channel = SSHChannel(launch: try scriptedHelper(in: base, pingReply: stalePing))
        let log = InstallLog()
        let outcome = await HelperInstaller.ensureInstalled(
            alias: "devbox", watchAs: .loginUser, channel: channel,
            runner: { data, alias, watchAs in
                #expect(!data.isEmpty)
                #expect(alias == "devbox")
                #expect(watchAs == .loginUser)
                await log.note()
            })
        #expect(outcome == .installed)
        #expect(await log.calls == 1)
        // The next request runs a fresh process, which is the pushed helper.
        let generation = await channel.generation
        _ = try await channel.request("ping")
        #expect(await channel.generation == generation + 1)
        await channel.shutdown()
    }

    @Test("sudo asking for a password means setup, but only when watching every user",
          .enabled(if: pythonAvailable))
    func sudoPasswordNeedsSetup() async throws {
        let base = try freshBase("helper-installer")
        defer { try? FileManager.default.removeItem(at: base) }
        for (watchAs, stderr) in [
            (WatchAs.everyUser, "sudo: a password is required\n"),
            (WatchAs.everyUser, "Warning: synthetic banner\nsudo: a terminal is required to read the password\n"),
            (WatchAs.loginUser, "sudo: a password is required\n"),
        ] {
            let channel = SSHChannel(launch: try scriptedHelper(in: base, pingReply: stalePing))
            let outcome = await HelperInstaller.ensureInstalled(
                alias: "devbox", watchAs: watchAs, channel: channel,
                runner: { _, _, _ in
                    throw HelperInstaller.InstallFailure(message: "helper install exited 1", stderr: stderr)
                })
            await channel.shutdown()
            if watchAs == .everyUser {
                #expect(outcome == .needsSetup(HelperInstaller.updateNeedsSetupMessage))
            } else {
                #expect(outcome == .failed("helper install exited 1"))
            }
        }
    }

    @Test("a ping answered with ok false counts as a failure", .enabled(if: pythonAvailable))
    func refusedPingIsAFailure() async throws {
        let base = try freshBase("helper-installer")
        defer { try? FileManager.default.removeItem(at: base) }
        let channel = SSHChannel(launch: try scriptedHelper(
            in: base, pingReply: #"{"ok": False, "error": "synthetic"}"#))
        let check = await HelperInstaller.check(channel: channel)
        guard case .unreachable = check else {
            Issue.record("expected unreachable, got \(check)")
            return
        }
        #expect(await channel.currentBackoff == 2)
        #expect(await channel.reachability != .reachable)
    }

    @Test("a local launch is never installed over ssh", .enabled(if: pythonAvailable))
    func localLaunchNeverInstalls() async throws {
        let base = try freshBase("helper-installer")
        defer { try? FileManager.default.removeItem(at: base) }
        let channel = SSHChannel(launch: try scriptedHelper(in: base, pingReply: stalePing))
        let outcome = await HelperInstaller.ensureInstalled(alias: "devbox", watchAs: .everyUser, channel: channel)
        await channel.shutdown()
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }
}
