import Foundation
import SQLite3
import Testing
@testable import SwarmBar

private let pythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// One synthetic host home holding state for every tool, the real helper
/// run locally against it, and the mirror its snapshot lands in. The
/// helper's own process table is swapped for a synthetic one before
/// discovery runs: the real table is this Mac's, which holds whatever
/// agents happen to be running here, and none of them belong to the
/// synthetic home.
private struct Rig {
    static let claudeID = UUID(uuidString: "6f1c2a44-0b7e-4d0e-9a51-3c2d8e7f9a10")!
    static let codexID = "0198a6b9-1111-7abc-9def-0123456789ab"
    static let grokID = "3a9b7c1d-2e4f-4a6b-8c0d-1e2f3a4b5c6d"
    static let conversation = "c0ffee00-1111-4222-8333-444455556666"

    static let claudePid = 4101
    static let codexPid = 4102
    static let kimiPid = 4103
    static let bearPid = 4104
    static let openCodePid = 4105
    static let grokPid = 4106
    static let agyPid = 4107

    let base: URL
    let home: String
    let mirror: RemoteMirror
    let snapshot: RemoteSnapshot

    /// The temp home and its mirror, both under `base`.
    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    static func make() async throws -> Rig {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-discovery-\(UUID().uuidString)")
        do {
            return try await make(base: base)
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
    }

    private static func make(base: URL) async throws -> Rig {
        let home = base.appendingPathComponent("home/u")
        try writeHome(home)

        let script = try #require(Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"))
        let channel = SSHChannel(launch: .local(
            python: "/usr/bin/python3", script: script.path, homes: [home.path]))
        let shipped: RemoteSnapshot
        do {
            shipped = try await channel.snapshot()
        } catch {
            await channel.shutdown()
            throw error
        }
        await channel.shutdown()

        let mirror = RemoteMirror(root: base.appendingPathComponent("mirror"))
        try mirror.apply(shipped)
        return Rig(
            base: base, home: home.path, mirror: mirror,
            snapshot: shipped.replacingProcesses(processes(home: home.path), failed: false))
    }

    /// The synthetic process table: one live process per tool, each placed
    /// where that tool's liveness looks for it.
    static func processes(home: String) -> [RemoteProcessRecord] {
        let agy = home + "/.gemini/antigravity-cli"
        let rollout = home + "/.codex/sessions/2026/08/01/rollout-2026-08-01T10-00-00-\(codexID).jsonl"
        return [
            record(claudePid, "claude", cwd: "/home/u/claude-proj"),
            record(codexPid, "codex", cwd: "/home/u/demo", open: [rollout]),
            record(kimiPid, "kimi-code", cwd: "/home/u/kimi-proj"),
            record(bearPid, "bearcode", cwd: "/home/u/bear-proj"),
            record(openCodePid, "opencode", cwd: "/home/u/open-proj"),
            record(grokPid, "grok", cwd: "/home/u/grok-proj"),
            record(
                agyPid, "agy", cwd: "/home/u/agy-proj",
                open: [agy + "/presence/\(conversation).lock"], screen: "synthetic screen"),
        ]
    }

    static func record(
        _ pid: Int, _ comm: String, cwd: String, open: [String] = [],
        openFailed: Bool = false, screen: String? = nil
    ) -> RemoteProcessRecord {
        RemoteProcessRecord(
            pid: pid, ppid: 1, user: "u", comm: comm, args: comm, cwd: cwd, tty: "pts/1",
            pane: nil, open: open, openFailed: openFailed, screen: screen)
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeHome(_ home: URL) throws {
        let iso = ISO8601DateFormatter().string(from: .now)

        try write(
            try fixture("claude-working"),
            to: home.appendingPathComponent(".claude/projects/-home-u-claude-proj/\(claudeID.uuidString.lowercased()).jsonl"))
        try write(
            "{\"sessionId\":\"\(claudeID.uuidString.lowercased())\",\"pid\":\(claudePid)}",
            to: home.appendingPathComponent(".claude/sessions/\(claudePid).json"))

        try write(
            try fixture("codex-running"),
            to: home.appendingPathComponent(
                ".codex/sessions/2026/08/01/rollout-2026-08-01T10-00-00-\(codexID).jsonl"))

        for (dot, project, uuid) in [
            (".kimi-code", "kimi-proj", "5e2d1c0b-aaaa-4bbb-8ccc-0d1e2f3a4b5c"),
            (".bearcode", "bear-proj", "7a6b5c4d-dddd-4eee-9fff-1a2b3c4d5e6f"),
        ] {
            let root = home.appendingPathComponent(dot)
            // The index names the session directory by its absolute path on
            // the host, exactly as the tool writes it.
            let sessionDir = root.appendingPathComponent("sessions/wd_\(project)_ab12cd/session_\(uuid)")
            try write(
                "{\"sessionId\":\"session_\(uuid)\",\"sessionDir\":\"\(sessionDir.path)\",\"workDir\":\"/home/u/\(project)\"}\n",
                to: root.appendingPathComponent("session_index.jsonl"))
            try write(
                "{\"workDir\":\"/home/u/\(project)\",\"updatedAt\":\"\(iso)\"}",
                to: sessionDir.appendingPathComponent("state.json"))
            try write(
                try fixture("kimi-wire"),
                to: sessionDir.appendingPathComponent("agents/main/wire.jsonl"))
        }

        try writeOpenCodeDB(home.appendingPathComponent(".local/share/opencode/opencode.db"))

        try write(
            "{\"info\":{\"id\":\"\(grokID)\",\"cwd\":\"/home/u/grok-proj\"},\"created_at\":\"\(iso)\",\"updated_at\":\"\(iso)\"}",
            to: home.appendingPathComponent(".grok/sessions/%2Fhome%2Fu%2Fgrok-proj/\(grokID)/summary.json"))
        try write(
            "[{\"session_id\":\"\(grokID)\",\"pid\":\(grokPid)}]",
            to: home.appendingPathComponent(".grok/active_sessions.json"))

        let agy = home.appendingPathComponent(".gemini/antigravity-cli")
        try write("", to: agy.appendingPathComponent("presence/\(conversation).lock"))
        try write(
            try fixture("agy-working"),
            to: agy.appendingPathComponent("brain/\(conversation)/.system_generated/logs/transcript.jsonl"))
        let millis = Int(Date.now.timeIntervalSince1970 * 1000)
        try write(
            "{\"conversationId\":\"\(conversation)\",\"workspace\":\"/home/u/agy-proj\",\"display\":\"synthetic prompt\",\"timestamp\":\(millis)}\n",
            to: agy.appendingPathComponent("history.jsonl"))
    }

    private static func writeOpenCodeDB(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let millis = Int(Date.now.timeIntervalSince1970 * 1000)
        let sql = """
        CREATE TABLE session(id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, parent_id TEXT);
        INSERT INTO session VALUES ('ses_synthetic', '/home/u/open-proj', 'synthetic', \(millis), \(millis), NULL);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

private extension RemoteSnapshot {
    /// The synthetic table belongs to user `u`, so every home is handed to
    /// `u` as well. The helper names the temp home's real owner, which is
    /// whoever runs the tests on this Mac.
    func replacingProcesses(_ processes: [RemoteProcessRecord], failed: Bool) -> RemoteSnapshot {
        RemoteSnapshot(
            ok: ok, protocolVersion: protocolVersion, stream: stream, hostname: hostname,
            system: system, now: now, homes: homes.map { RemoteHome(path: $0.path, user: "u") },
            files: files, dirs: dirs, omitted: omitted,
            warnings: warnings, processes: processes, processesFailed: failed)
    }
}

@Suite("Remote discovery")
struct RemoteDiscoveryTests {
    let hostID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    @Test("every tool produces a row tagged with its host", .enabled(if: pythonAvailable))
    func everyToolProducesARowWithHost() async throws {
        let rig = try await Rig.make()
        defer { rig.remove() }
        let result = RemoteDiscovery.sessions(
            snapshot: rig.snapshot, mirror: rig.mirror, hostID: hostID, hostName: "devbox", now: .now)
        for tool in AgentTool.allCases {
            let rows = result[tool] ?? []
            #expect(rows.count == 1, "\(tool) produced \(rows.count) rows")
            #expect(rows.allSatisfy { $0.host == "devbox" && $0.tool == tool })
            #expect(rows.allSatisfy { $0.processAlive }, "\(tool) should be alive")
        }
        // Pids come through from discovery, and screen text from the
        // process record, so remote answering has something to aim at.
        #expect(result[.claudeCode]?.first?.pid == pid_t(Rig.claudePid))
        #expect(result[.codex]?.first?.pid == pid_t(Rig.codexPid))
        #expect(result[.kimiCode]?.first?.pid == pid_t(Rig.kimiPid))
        #expect(result[.bearCode]?.first?.pid == pid_t(Rig.bearPid))
        #expect(result[.openCode]?.first?.pid == pid_t(Rig.openCodePid))
        #expect(result[.grokBuild]?.first?.pid == pid_t(Rig.grokPid))
        #expect(result[.antigravity]?.first?.pid == pid_t(Rig.agyPid))
        #expect(result[.antigravity]?.first?.projectName == "agy-proj")
    }

    @Test("session ids are scoped to the host", .enabled(if: pythonAvailable))
    func idsAreHostScoped() async throws {
        let rig = try await Rig.make()
        defer { rig.remove() }
        let result = RemoteDiscovery.sessions(
            snapshot: rig.snapshot, mirror: rig.mirror, hostID: hostID, hostName: "devbox", now: .now)
        let claude = try #require(result[.claudeCode]?.first)
        #expect(claude.id == RemoteIdentity.sessionID(
            hostID: hostID, home: rig.home, localID: Rig.claudeID))
        #expect(claude.id != Rig.claudeID)
        let codex = try #require(result[.codex]?.first)
        let codexLocal = try #require(UUID(uuidString: Rig.codexID))
        #expect(codex.id == RemoteIdentity.sessionID(hostID: hostID, home: rig.home, localID: codexLocal))
    }

    @Test("the Claude status is what the local parser reads", .enabled(if: pythonAvailable))
    func claudeStatusMatchesLocalParser() async throws {
        let rig = try await Rig.make()
        defer { rig.remove() }
        let now = Date.now
        let result = RemoteDiscovery.sessions(
            snapshot: rig.snapshot, mirror: rig.mirror, hostID: hostID, hostName: "devbox", now: now)
        let expected = try #require(ClaudeSessionParser.parse(tail: try fixture("claude-working"), now: now))
        #expect(result[.claudeCode]?.first?.status == expected.status)
        #expect(result[.claudeCode]?.first?.projectName == "demo")
    }

    @Test("an empty snapshot still answers for all seven tools")
    func allSevenKeysPresent() {
        let mirror = RemoteMirror(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-discovery-\(UUID().uuidString)"))
        let snapshot = RemoteSnapshot(
            ok: true, protocolVersion: 3, stream: "s", hostname: "devbox", system: "Linux", now: 0,
            homes: [], files: [], dirs: [], omitted: [], warnings: [], processes: [],
            processesFailed: false)
        let result = RemoteDiscovery.sessions(
            snapshot: snapshot, mirror: mirror, hostID: hostID, hostName: "devbox", now: .now)
        #expect(Set(result.keys) == Set(AgentTool.allCases))
        #expect(result.values.allSatisfy { $0.isEmpty })
    }

    @Test("a failed process list marks nothing alive", .enabled(if: pythonAvailable))
    func failedProcessListMarksNothingAlive() async throws {
        let rig = try await Rig.make()
        defer { rig.remove() }
        let failed = rig.snapshot.replacingProcesses(Rig.processes(home: rig.home), failed: true)
        let result = RemoteDiscovery.discover(
            snapshot: failed, mirror: rig.mirror, hostID: hostID, hostName: "devbox", now: .now)
        let rows = result.sessions.values.flatMap { $0 }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { !$0.processAlive && $0.pid == nil })
        #expect(result.processesFailed)
        #expect(result.warnings.contains { $0.contains("process list") })
        #expect(result.unverifiedTools == Set(AgentTool.allCases))
    }

    @Test("a readable process table verifies every tool", .enabled(if: pythonAvailable))
    func readableTableVerifiesEveryTool() async throws {
        let rig = try await Rig.make()
        defer { rig.remove() }
        let result = RemoteDiscovery.discover(
            snapshot: rig.snapshot, mirror: rig.mirror, hostID: hostID, hostName: "devbox", now: .now)
        #expect(result.unverifiedTools.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("a home the mirror cannot hold is skipped with a warning")
    func unsafeHomeIsSkipped() {
        let mirror = RemoteMirror(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-discovery-\(UUID().uuidString)"))
        let snapshot = RemoteSnapshot(
            ok: true, protocolVersion: 3, stream: "s", hostname: "devbox", system: "Linux", now: 0,
            homes: [RemoteHome(path: "/home/../etc", user: "u")], files: [], dirs: [], omitted: [],
            warnings: [], processes: [], processesFailed: false)
        let result = RemoteDiscovery.discover(
            snapshot: snapshot, mirror: mirror, hostID: hostID, hostName: "devbox", now: .now)
        #expect(result.warnings.contains { $0.contains("/home/../etc") })
        #expect(result.sessions.values.allSatisfy { $0.isEmpty })
    }
}

/// Discovery over a mirror written by hand rather than by the helper, for
/// the cases that turn on the process table and not on what was shipped.
@Suite("Remote discovery against a hand-built mirror")
struct RemoteDiscoveryMirrorTests {
    let hostID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let mirror = RemoteMirror(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-discovery-\(UUID().uuidString)"))

    private func write(_ text: String, remote path: String) throws {
        let url = try #require(mirror.local(path))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func snapshot(
        homes: [RemoteHome], processes: [RemoteProcessRecord]
    ) -> RemoteSnapshot {
        RemoteSnapshot(
            ok: true, protocolVersion: 3, stream: "s", hostname: "devbox", system: "Linux", now: 0,
            homes: homes, files: [], dirs: [], omitted: [], warnings: [], processes: processes,
            processesFailed: false)
    }

    private func discover(_ snapshot: RemoteSnapshot) -> RemoteDiscovery.Result {
        RemoteDiscovery.discover(
            snapshot: snapshot, mirror: mirror, hostID: hostID, hostName: "devbox", now: .now)
    }

    /// One Kimi session under /home/u, working in /home/u/proj.
    private func writeKimiSession(sessionDir: String = "/home/u/.kimi-code/sessions/wd_proj_ab12/session_a") throws {
        try write(
            "{\"sessionId\":\"session_a\",\"sessionDir\":\"\(sessionDir)\",\"workDir\":\"/home/u/proj\"}\n",
            remote: "/home/u/.kimi-code/session_index.jsonl")
        let iso = ISO8601DateFormatter().string(from: .now)
        try write(
            "{\"workDir\":\"/home/u/proj\",\"updatedAt\":\"\(iso)\"}",
            remote: "/home/u/.kimi-code/sessions/wd_proj_ab12/session_a/state.json")
    }

    @Test func anotherUsersProcessNeverMarksASessionAlive() throws {
        defer { try? FileManager.default.removeItem(at: mirror.root) }
        try writeKimiSession()
        let homes = [RemoteHome(path: "/home/u", user: "u"), RemoteHome(path: "/root", user: "root")]
        // root runs kimi in u's project directory, under a higher pid.
        let rootKimi = Rig.record(900, "kimi-code", cwd: "/home/u/proj")
        let rootOwned = RemoteProcessRecord(
            pid: rootKimi.pid, ppid: 1, user: "root", comm: rootKimi.comm, args: rootKimi.args,
            cwd: rootKimi.cwd, tty: "", pane: nil, open: [], openFailed: false, screen: nil)

        let onlyRoot = discover(snapshot(homes: homes, processes: [rootOwned]))
        let unseen = try #require(onlyRoot.sessions[.kimiCode]?.first)
        #expect(!unseen.processAlive)
        #expect(unseen.pid == nil)

        let both = discover(snapshot(
            homes: homes, processes: [rootOwned, Rig.record(300, "kimi-code", cwd: "/home/u/proj")]))
        let seen = try #require(both.sessions[.kimiCode]?.first)
        #expect(seen.processAlive)
        #expect(seen.pid == 300)
    }

    /// A home copied to a second user carries its transcripts, and their
    /// ids, along with it. Each copy is its own session and gets its own row.
    @Test func sameLocalIDInTwoHomesGivesTwoRows() throws {
        defer { try? FileManager.default.removeItem(at: mirror.root) }
        let shared = UUID()
        let transcript = try fixture("claude-working")
        for home in ["/home/u", "/root"] {
            try write(
                transcript,
                remote: "\(home)/.claude/projects/-home-u-demo/\(shared.uuidString.lowercased()).jsonl")
        }
        let result = discover(snapshot(
            homes: [RemoteHome(path: "/home/u", user: "u"), RemoteHome(path: "/root", user: "root")],
            processes: []))
        let ids = (result.sessions[.claudeCode] ?? []).map(\.id)
        #expect(ids.count == 2)
        #expect(Set(ids) == [
            RemoteIdentity.sessionID(hostID: hostID, home: "/home/u", localID: shared),
            RemoteIdentity.sessionID(hostID: hostID, home: "/root", localID: shared),
        ])
    }

    @Test func unreadableCodexLeavesOnlyCodexUnverified() {
        let result = discover(snapshot(
            homes: [RemoteHome(path: "/home/u", user: "u")],
            processes: [Rig.record(10, "codex", cwd: "/home/u/a", openFailed: true)]))
        #expect(result.unverifiedTools == [.codex])
        #expect(result.warnings.contains { $0.contains("pid 10") })
    }

    @Test func unreadableAgyLeavesOnlyAntigravityUnverified() {
        let result = discover(snapshot(
            homes: [RemoteHome(path: "/home/u", user: "u")],
            processes: [Rig.record(11, "agy", cwd: "/home/u/a", openFailed: true)]))
        #expect(result.unverifiedTools == [.antigravity])
    }

    /// Only Codex and Antigravity read liveness from held files, so no
    /// other tool is put in doubt by an unreadable process.
    @Test func unreadableProcessOfAnotherToolVerifiesEverything() {
        let result = discover(snapshot(
            homes: [RemoteHome(path: "/home/u", user: "u")],
            processes: [Rig.record(12, "claude", cwd: "/home/u/a", openFailed: true)]))
        #expect(result.unverifiedTools.isEmpty)
    }

    /// A user with no scanned home has no sessions to doubt, and its
    /// processes are not worth a warning.
    @Test func unreadableProcessOfAnUnscannedUserIsIgnored() {
        let foreign = RemoteProcessRecord(
            pid: 13, ppid: 1, user: "root", comm: "codex", args: "codex", cwd: "/root",
            tty: "", pane: nil, open: [], openFailed: true, screen: nil)
        let result = discover(snapshot(homes: [RemoteHome(path: "/home/u", user: "u")], processes: [foreign]))
        #expect(result.unverifiedTools.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func refusedKimiSessionDirIsReported() throws {
        defer { try? FileManager.default.removeItem(at: mirror.root) }
        try writeKimiSession(sessionDir: "/home/u/../../etc/session_a")
        let result = discover(snapshot(homes: [RemoteHome(path: "/home/u", user: "u")], processes: []))
        #expect(result.sessions[.kimiCode]?.isEmpty == true)
        #expect(result.warnings.contains { $0.contains("/home/u/../../etc/session_a") })
    }

    /// One shared tail cache serves this Mac and every remote home. A
    /// remote pass must evict only beneath the roots it scanned, or it
    /// would throw away the local monitor's tails on every poll.
    @Test func remoteDiscoveryLeavesOtherRootsCached() throws {
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-elsewhere-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: mirror.root)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let cached = elsewhere.appendingPathComponent(".claude/projects/-home-x/\(UUID().uuidString).jsonl")
        let modified = Date()
        _ = ClaudeCodeMonitor.tailCache.value(for: cached, size: 1, modified: modified) { "seeded" }

        try write(
            try fixture("claude-working"),
            remote: "/home/u/.claude/projects/-home-u-demo/\(UUID().uuidString.lowercased()).jsonl")
        let result = discover(snapshot(homes: [RemoteHome(path: "/home/u", user: "u")], processes: []))
        #expect(result.sessions[.claudeCode]?.count == 1)

        var recomputed = false
        let value = ClaudeCodeMonitor.tailCache.value(for: cached, size: 1, modified: modified) {
            recomputed = true; return "again"
        }
        #expect(!recomputed)
        #expect(value == "seeded")
    }
}

@Suite("Remote process facts")
struct RemoteProcessFactsTests {
    private let mirror = RemoteMirror(root: URL(fileURLWithPath: "/tmp/remote-facts-mirror"))

    private func facts(_ records: [RemoteProcessRecord], failed: Bool = false) -> RemoteProcessFacts {
        RemoteProcessFacts(processes: records, failed: failed, mirror: mirror)
    }

    private func local(_ remote: String) -> String {
        mirror.local(remote)!.path
    }

    @Test func livenessIsMembershipInTheTable() {
        let table = facts([Rig.record(10, "claude", cwd: "/home/u/a")])
        #expect(table.isAlive(10))
        #expect(!table.isAlive(11))
    }

    @Test func countsByCwdAmongNamedProcesses() {
        let table = facts([
            Rig.record(10, "kimi", cwd: "/home/u/a"),
            Rig.record(11, "kimi-code", cwd: "/home/u/a"),
            Rig.record(12, "claude", cwd: "/home/u/a"),
            Rig.record(13, "kimi-code", cwd: "/home/u/b"),
        ])
        #expect(table.directoryCounts(processNames: ["kimi", "kimi-code"]) == ["/home/u/a": 2, "/home/u/b": 1])
        #expect(table.directoryCounts(processNames: ["opencode"]).isEmpty)
    }

    @Test func nameOrCommandPatternMatches() {
        let node = RemoteProcessRecord(
            pid: 20, ppid: 1, user: "u", comm: "node",
            args: "node /opt/bearcode-cli/apps/kimi-code/dist/main.mjs", cwd: "/home/u/c",
            tty: "", pane: nil, open: [], openFailed: false, screen: nil)
        let table = facts([Rig.record(21, "bearcode", cwd: "/home/u/d"), node])
        #expect(table.directoryCounts(
            processName: "bearcode", orCommandPattern: "bearcode-cli/apps/kimi-code/dist/main.mjs")
            == ["/home/u/c": 1, "/home/u/d": 1])
    }

    @Test func codexRolloutsKeyByTheLocalSuffix() {
        let uuid = "0198a6b9-1111-7abc-9def-0123456789ab"
        let root = "/home/u/.codex/sessions"
        let table = facts([
            Rig.record(30, "codex", cwd: "/home/u/a", open: [
                "\(root)/2026/08/01/rollout-2026-08-01T10-00-00-\(uuid.uppercased()).jsonl",
                "/home/u/elsewhere/rollout-x.jsonl",
            ]),
        ])
        #expect(table.codexPidsBySessionSuffix(sessionsRoot: local(root)) == ["\(uuid).jsonl": 30])
    }

    @Test func heldFilesAreRemotePathsUnderTheDirectory() {
        let presence = "/home/u/.gemini/antigravity-cli/presence"
        let table = facts([
            Rig.record(40, "agy", cwd: "/home/u/a", open: ["\(presence)/conv-1.lock", "/home/u/other.lock"]),
            Rig.record(41, "claude", cwd: "/home/u/a", open: ["\(presence)/conv-2.lock"]),
        ])
        #expect(table.heldFiles(processName: "agy", inDirectory: local(presence))
            == ["\(presence)/conv-1.lock": 40])
    }

    @Test func unknownOpenFilesContributeNothingAndAreReported() {
        let presence = "/home/u/.gemini/antigravity-cli/presence"
        let table = facts([
            Rig.record(50, "agy", cwd: "/home/u/a", openFailed: true),
            Rig.record(51, "agy", cwd: "/home/u/b", open: ["\(presence)/conv-9.lock"]),
        ])
        #expect(table.heldFiles(processName: "agy", inDirectory: local(presence))
            == ["\(presence)/conv-9.lock": 51])
        #expect(table.unreadablePids == [50])
        // Liveness by working directory does not need open files.
        #expect(table.directoryCounts(processNames: ["agy"]) == ["/home/u/a": 1, "/home/u/b": 1])
        #expect(table.isAlive(50))
    }

    @Test func pidByCwdIsTheNewestMatch() {
        let table = facts([
            Rig.record(60, "opencode", cwd: "/home/u/a"),
            Rig.record(75, "opencode", cwd: "/home/u/a"),
            Rig.record(90, "opencode", cwd: "/home/u/b"),
            Rig.record(99, "claude", cwd: "/home/u/a"),
        ])
        #expect(table.pid(processNames: ["opencode"], cwd: "/home/u/a") == 75)
        #expect(table.pid(processNames: ["opencode"], cwd: "/home/u/z") == nil)
        #expect(table.cwd(pid: 90) == "/home/u/b")
        #expect(table.cwd(pid: 1) == nil)
    }

    @Test func aFailedTableAnswersNothing() {
        let table = facts([Rig.record(70, "claude", cwd: "/home/u/a")], failed: true)
        #expect(!table.isAlive(70))
        #expect(table.directoryCounts(processNames: ["claude"]).isEmpty)
        #expect(table.cwd(pid: 70) == nil)
        #expect(table.pid(processNames: ["claude"], cwd: "/home/u/a") == nil)
    }
}
