import Foundation
import Testing
@testable import SwarmBar

/// Fixed answers for every process question discovery asks, so a test can
/// say which sessions are alive without any real process existing. Each
/// table is keyed the way the real query is asked, so a monitor that asks
/// about the wrong directory gets nothing back and the test notices.
private struct FakeFacts: ProcessFacts {
    var alive: Set<Int> = []
    var counts: [String: Int] = [:]
    var codex: (sessionsRoot: String, pids: [String: Int])?
    var held: (directory: String, files: [String: Int])?
    var cwds: [Int: String] = [:]
    var pidsByCwd: [String: Int] = [:]

    func isAlive(_ pid: Int) -> Bool { alive.contains(pid) }
    func directoryCounts(processNames: [String]) -> [String: Int] { counts }
    func directoryCounts(processName: String, orCommandPattern: String) -> [String: Int] { counts }
    func codexPidsBySessionSuffix(sessionsRoot: String) -> [String: Int] {
        guard let codex, codex.sessionsRoot == sessionsRoot else { return [:] }
        return codex.pids
    }
    func heldFiles(processName: String, inDirectory: String) -> [String: Int] {
        guard processName == "agy", let held, held.directory == inDirectory else { return [:] }
        return held.files
    }
    func cwd(pid: Int) -> String? { cwds[pid] }
    func pid(processNames: [String], cwd: String) -> Int? { pidsByCwd[cwd] }
}

@MainActor
struct DiscoveryContextTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func context(home: URL, facts: FakeFacts, resolvesPids: Bool = false) -> DiscoveryContext {
        var context = DiscoveryContext(
            home: home,
            processes: facts,
            locate: { URL(fileURLWithPath: $0) },
            screen: { _ in nil })
        context.resolvesPids = resolvesPids
        return context
    }

    @Test func localContextIsThisMac() {
        let local = DiscoveryContext.local()
        #expect(local.home == FileManager.default.homeDirectoryForCurrentUser)
        #expect(local.locate("/home/u/x").path == "/home/u/x")
        #expect(local.resolvesPids == false)
    }

    @Test func claudeLivenessComesFromFacts() throws {
        let home = try makeHome()
        let id = UUID()
        try write(
            try fixture("claude-working"),
            to: home.appendingPathComponent(".claude/projects/-home-u-demo/\(id.uuidString).jsonl"))
        try write(
            "{\"sessionId\":\"\(id.uuidString)\",\"pid\":4242}",
            to: home.appendingPathComponent(".claude/sessions/s.json"))

        let alive = ClaudeCodeMonitor.discover(
            now: .now, context: context(home: home, facts: FakeFacts(alive: [4242])))
        #expect(alive.count == 1)
        #expect(alive.first?.processAlive == true)
        #expect(alive.first?.pid == 4242)

        let dead = ClaudeCodeMonitor.discover(
            now: .now, context: context(home: home, facts: FakeFacts(alive: [])))
        #expect(dead.count == 1)
        #expect(dead.first?.processAlive == false)
        #expect(dead.first?.pid == nil)
    }

    @Test func codexLivenessComesFromFacts() throws {
        let home = try makeHome()
        let uuid = "0198a6b9-1111-7abc-9def-0123456789ab"
        let sessionsRoot = home.appendingPathComponent(".codex/sessions")
        try write(
            try fixture("codex-running"),
            to: sessionsRoot.appendingPathComponent(
                "2026/08/01/rollout-2026-08-01T10-00-00-\(uuid).jsonl"))

        var facts = FakeFacts()
        facts.codex = (sessionsRoot.path, ["\(uuid).jsonl": 5151])
        let alive = CodexMonitor.discover(now: .now, context: context(home: home, facts: facts))
        #expect(alive.count == 1)
        #expect(alive.first?.processAlive == true)
        #expect(alive.first?.pid == 5151)

        let dead = CodexMonitor.discover(now: .now, context: context(home: home, facts: FakeFacts()))
        #expect(dead.first?.processAlive == false)
        #expect(dead.first?.pid == nil)
    }

    @Test func kimiSessionDirIsLocatedThroughContext() throws {
        let tree = try makeHome()
        let root = tree.appendingPathComponent("home/u/.kimi-code")
        let remoteDir = "/home/u/.kimi-code/sessions/a"
        try write(
            "{\"sessionId\":\"session_a\",\"sessionDir\":\"\(remoteDir)\",\"workDir\":\"/home/u/proj\"}\n",
            to: root.appendingPathComponent("session_index.jsonl"))
        let iso = ISO8601DateFormatter().string(from: .now)
        try write(
            "{\"workDir\":\"/home/u/proj\",\"updatedAt\":\"\(iso)\"}",
            to: tree.appendingPathComponent("home/u/.kimi-code/sessions/a/state.json"))

        let located = KimiMonitor.discover(
            root: root, now: .now,
            locate: { URL(fileURLWithPath: tree.path + $0) })
        #expect(located.count == 1)
        #expect(located.first?.projectName == "proj")

        // Without the translation the path names a directory that does not
        // exist here, so the session cannot be found.
        let unlocated = KimiMonitor.discover(root: root, now: .now)
        #expect(unlocated.isEmpty)
    }

    @Test func kimiPidIsResolvedOnlyWhenTheContextAsks() throws {
        let home = try makeHome()
        let root = home.appendingPathComponent(".kimi-code")
        let sessionDir = root.appendingPathComponent("sessions/a")
        try write(
            "{\"sessionId\":\"session_a\",\"sessionDir\":\"\(sessionDir.path)\",\"workDir\":\"/home/u/proj\"}\n",
            to: root.appendingPathComponent("session_index.jsonl"))
        let iso = ISO8601DateFormatter().string(from: .now)
        try write(
            "{\"workDir\":\"/home/u/proj\",\"updatedAt\":\"\(iso)\"}",
            to: sessionDir.appendingPathComponent("state.json"))
        let facts = FakeFacts(counts: ["/home/u/proj": 1], pidsByCwd: ["/home/u/proj": 777])

        let remote = KimiMonitor.discover(
            now: .now, context: context(home: home, facts: facts, resolvesPids: true))
        #expect(remote.first?.processAlive == true)
        #expect(remote.first?.pid == 777)

        let local = KimiMonitor.discover(now: .now, context: context(home: home, facts: facts))
        #expect(local.first?.processAlive == true)
        #expect(local.first?.pid == nil)
    }

    @Test func grokActiveEntryUsesFactsNotKill() throws {
        let root = try makeHome().appendingPathComponent(".grok")
        let id = UUID().uuidString
        let iso = ISO8601DateFormatter().string(from: .now)
        try write(
            "{\"info\":{\"id\":\"\(id)\",\"cwd\":\"/home/u/proj\"},\"created_at\":\"\(iso)\",\"updated_at\":\"\(iso)\"}",
            to: root.appendingPathComponent("sessions/%2Fhome%2Fu%2Fproj/\(id)/summary.json"))
        // A pid that cannot belong to a live process on this Mac, so a
        // stray kill(pid, 0) would read it as dead and fail the test.
        try write(
            "[{\"session_id\":\"\(id)\",\"pid\":999999}]",
            to: root.appendingPathComponent("active_sessions.json"))

        let alive = GrokBuildMonitor.discover(root: root, now: .now, isAlive: { $0 == 999999 })
        #expect(alive.count == 1)
        #expect(alive.first?.processAlive == true)
        #expect(alive.first?.pid == 999999)
        #expect(alive.first?.status == .working(activity: "Working…"))

        let dead = GrokBuildMonitor.discover(root: root, now: .now, isAlive: { _ in false })
        #expect(dead.first?.processAlive == false)
        #expect(dead.first?.status == .idle)
    }

    @Test func antigravityLiveComesFromHeldFiles() throws {
        let home = try makeHome()
        let agyHome = home.appendingPathComponent(".gemini/antigravity-cli")
        let presence = AntigravityReader.presenceDirectory(home: agyHome).path
        var facts = FakeFacts(cwds: [3131: "/home/u/proj"])
        facts.held = (presence, ["\(presence)/conv-1.lock": 3131])

        #expect(AntigravityReader.liveConversations(home: agyHome, processes: facts) == ["conv-1": 3131])

        let sessions = AntigravityMonitor.discover(now: .now, context: context(home: home, facts: facts))
        #expect(sessions.count == 1)
        #expect(sessions.first?.pid == 3131)
        #expect(sessions.first?.processAlive == true)
        #expect(sessions.first?.projectName == "proj")
    }

    @Test func originToolReadsGivenHome() throws {
        let home = try makeHome()
        try write(
            "[{\"session_id\":\"grok-raw-id\"}]",
            to: home.appendingPathComponent(".grok/active_sessions.json"))
        #expect(HookServer.originTool(rawSessionID: "grok-raw-id", home: home) == .grokBuild)
        #expect(HookServer.originTool(rawSessionID: "grok-raw-id", home: try makeHome()) == .claudeCode)
    }
}
