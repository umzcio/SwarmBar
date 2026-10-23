import Foundation
import Testing
@testable import SwarmBar

/// Settings › Hosts: the row text and pill, the outage clock behind
/// "Unreachable for 4 min", checking a host again, and the per-tool
/// approval switches. Synthetic hosts, users and paths only.
@MainActor
@Suite("Settings hosts")
struct RemoteHostHintTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func assessment(
        _ status: HostAssessment.Status = .ready, hidden: Int? = 0
    ) -> HostAssessment {
        HostAssessment(status: status, suggestedWatchAs: nil, summary: "", hiddenSessions: hidden)
    }

    private static func process(_ comm: String, user: String) -> RemoteProcessRecord {
        RemoteProcessRecord(
            pid: 100, ppid: 1, user: user, comm: comm, args: comm, cwd: "/home/dev/work", tty: "pts/1",
            pane: nil, open: [], openFailed: false, screen: nil)
    }

    private static func probe(
        user: String = "dev", sudo: Bool = false, homes: [String] = ["/home/dev"],
        processes: [RemoteProcessRecord] = [], tools: [String] = [], installed: [String] = []
    ) -> ProbeResult {
        ProbeResult(
            alias: "devbox", protocolVersion: 3, system: "Linux", python: "3.12.3", hostname: "devbox",
            user: user, euid: user == "root" ? 0 : 1000, sudoOK: sudo,
            homes: homes.map { RemoteHome(path: $0, user: $0 == "/root" ? "root" : "dev") },
            processes: processes,
            tools: Dictionary(uniqueKeysWithValues: homes.map { ($0, tools) }),
            installed: Dictionary(uniqueKeysWithValues: homes.map { ($0, installed) }))
    }

    // MARK: Row text

    @Test func connectedEveryUserRowText() {
        let host = RemoteHost(alias: "alpha", watchAs: .everyUser)
        #expect(HostRowText.status(host: host, reachability: .reachable, sessions: 5,
                                   assessment: Self.assessment()) == "5 sessions · every user · connected")
        #expect(HostRowText.status(host: host, reachability: .reachable, sessions: 1,
                                   assessment: Self.assessment()) == "1 session · every user · connected")
        // Not checked yet changes nothing about what the connection shows.
        #expect(HostRowText.status(host: host, reachability: .reachable, sessions: 0,
                                   assessment: nil) == "No sessions · every user · connected")
    }

    @Test func offlineRowTextKeepsRows() {
        let host = RemoteHost(alias: "beta")
        let since = Self.now.addingTimeInterval(-4 * 60 - 20)
        #expect(HostRowText.status(
            host: host, reachability: .unreachable("timed out"), sessions: 3, assessment: Self.assessment(),
            unreachableSince: since, now: Self.now) == "Unreachable for 4 min · rows kept")
        // No rows to keep, so it does not claim any.
        #expect(HostRowText.status(
            host: host, reachability: .unreachable("timed out"), sessions: 0, assessment: nil,
            unreachableSince: since, now: Self.now) == "Unreachable for 4 min")
        #expect(HostRowText.status(
            host: host, reachability: .unreachable("timed out"), sessions: 2, assessment: nil,
            unreachableSince: Self.now.addingTimeInterval(-20), now: Self.now)
            == "Unreachable for under a minute · rows kept")
        #expect(HostRowText.status(
            host: host, reachability: .unreachable("timed out"), sessions: 2, assessment: nil,
            unreachableSince: nil, now: Self.now) == "Unreachable · rows kept")
    }

    @Test func partialRowNamesHiddenCount() {
        let host = RemoteHost(alias: "devbox", watchAs: .loginUser)
        #expect(HostRowText.status(
            host: host, reachability: .reachable, sessions: 0, assessment: Self.assessment(hidden: 2),
            loginUser: "dev", hiddenUsers: ["root"]) == "Just dev · 2 root sessions hidden")
        #expect(HostRowText.status(
            host: host, reachability: .reachable, sessions: 1, assessment: Self.assessment(hidden: 1),
            loginUser: "dev", hiddenUsers: ["root"]) == "1 session · just dev · 1 root session hidden")
        #expect(HostRowText.status(
            host: host, reachability: .reachable, sessions: 0, assessment: Self.assessment(hidden: 3),
            loginUser: "dev", hiddenUsers: ["root", "ops"]) == "Just dev · 3 sessions from other users hidden")
    }

    /// nil is "could not tell", which is never the same as "none hidden".
    @Test func unknownHiddenCountSaysNothing() {
        let host = RemoteHost(alias: "devbox", watchAs: .loginUser)
        let text = HostRowText.status(
            host: host, reachability: .reachable, sessions: 3, assessment: Self.assessment(hidden: nil),
            loginUser: "dev")
        #expect(text == "3 sessions · just dev · connected")
        #expect(!text.contains("hidden"))
        #expect(HostRowText.status(
            host: host, reachability: .reachable, sessions: 3, assessment: Self.assessment(hidden: 0),
            loginUser: "dev") == "3 sessions · just dev · connected")
        // Before any check the login user's name is unknown too.
        #expect(HostRowText.status(host: host, reachability: nil, sessions: 0, assessment: nil)
            == "No sessions · just you · connecting")
    }

    @Test func needsSetupAndFailedCheckSayWhy() {
        let host = RemoteHost(alias: "alpha")
        #expect(HostRowText.status(host: host, reachability: .needsSetup("Run the setup command."),
                                   sessions: 2, assessment: nil) == "Run the setup command.")
        #expect(HostRowText.status(host: host, reachability: .reachable, sessions: 2,
                                   assessment: Self.assessment(.cantConnect(.timedOut)))
            == HostProblem.timedOut.message)
        // A disabled host has no monitor, so "connecting" would never end.
        #expect(HostRowText.status(host: RemoteHost(alias: "beta", isEnabled: false), reachability: nil,
                                   sessions: 0, assessment: nil) == "Not being watched")
    }

    @Test func pillForEachState() {
        let every = RemoteHost(alias: "alpha")
        let login = RemoteHost(alias: "devbox", watchAs: .loginUser)
        #expect(HostRowText.pill(host: every, reachability: .reachable, assessment: Self.assessment()) == .ready)
        #expect(HostRowText.pill(host: login, reachability: .reachable,
                                 assessment: Self.assessment(hidden: 2)) == .partial)
        #expect(HostRowText.pill(host: login, reachability: .reachable,
                                 assessment: Self.assessment(hidden: nil)) == .ready)
        #expect(HostRowText.pill(host: every, reachability: .reachable,
                                 assessment: Self.assessment(.needsSetup(["x"]))) == .needsSetup)
        #expect(HostRowText.pill(host: every, reachability: .needsSetup("x"),
                                 assessment: Self.assessment()) == .needsSetup)
        #expect(HostRowText.pill(host: every, reachability: .unreachable("down"),
                                 assessment: Self.assessment()) == .offline)
        #expect(HostRowText.pill(host: every, reachability: .reachable,
                                 assessment: Self.assessment(.cantConnect(.keyRejected))) == .offline)
        #expect(HostRowText.Pill.ready.label == "Ready")
        #expect(HostRowText.Pill.needsSetup.label == "Needs setup")
        #expect(HostRowText.Pill.offline.label == "Offline")
        #expect(HostRowText.Pill.partial.label == "Partial")
        #expect(HostRowText.Pill.notChecked.label == "Not checked yet")
    }

    /// A connected host nobody has checked is unknown, never Ready.
    @Test func uncheckedHostIsNotCheckedYet() {
        let host = RemoteHost(alias: "alpha")
        #expect(HostRowText.pill(host: host, reachability: .reachable, assessment: nil) == .notChecked)
        #expect(HostRowText.pill(host: host, reachability: nil, assessment: nil) == .notChecked)
        #expect(HostRowText.pill(host: host, reachability: .connecting, assessment: nil) == .notChecked)
        // Reachability alone still says Offline and Needs setup.
        #expect(HostRowText.pill(host: host, reachability: .unreachable("down"), assessment: nil) == .offline)
        #expect(HostRowText.pill(host: host, reachability: .needsSetup("x"), assessment: nil) == .needsSetup)
    }

    // MARK: Tool switches

    @Test func toggleTitlesFollowHowEachToolIsAnswered() {
        #expect(HostRowText.toggleTitle(.claudeCode) == "Claude Code approvals")
        #expect(HostRowText.toggleTitle(.kimiCode) == "Kimi Code approvals")
        #expect(HostRowText.toggleTitle(.bearCode) == "BearCode approvals")
        #expect(HostRowText.toggleTitle(.openCode) == "OpenCode approvals")
        #expect(HostRowText.toggleTitle(.codex) == "Codex keystroke answers")
        #expect(HostRowText.toggleTitle(.grokBuild) == "Grok Build keystroke answers")
        #expect(HostRowText.toggleTitle(.antigravity) == "Antigravity keystroke answers")
    }

    @Test func presentToolsJoinCheckSnapshotAndSessionsInToolOrder() {
        let tools = HostRowText.presentTools(
            checked: [.grokBuild], processes: [Self.process("kimi-code", user: "root")],
            sessions: [.claudeCode])
        #expect(tools == [.claudeCode, .kimiCode, .grokBuild])
        #expect(HostRowText.presentTools(checked: nil, processes: [], sessions: []) == [])
    }

    @Test func approvalsToggleWritesApprovalsOffThroughTheRegistry() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let registry = RemoteHostRegistry(defaults: defaults)
        let host = RemoteHost(alias: "devbox")
        registry.upsert(host)

        registry.upsert(host.settingApprovals(false, for: .grokBuild))
        #expect(RemoteHostRegistry(defaults: defaults).hosts.first?.approvalsOff == [.grokBuild])

        let off = registry.host(id: host.id)!
        #expect(off.approvalsOn(for: .grokBuild) == false)
        #expect(off.approvalsOn(for: .claudeCode))
        registry.upsert(off.settingApprovals(true, for: .grokBuild))
        #expect(RemoteHostRegistry(defaults: defaults).hosts.first?.approvalsOff == [])
    }

    // MARK: Unreachable since

    @Test func storeRecordsWhenAnOutageBegan() {
        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let t0 = Self.now, t1 = t0.addingTimeInterval(60), t2 = t0.addingTimeInterval(600)
        store.noteRemoteReachability(host: "alpha", .reachable, now: t0)
        #expect(store.remoteUnreachableSince["alpha"] == nil)

        store.noteRemoteReachability(host: "alpha", .unreachable("timed out"), now: t0)
        #expect(store.remoteUnreachableSince["alpha"] == t0)
        // A different reason is the same outage, so the clock keeps running.
        store.noteRemoteReachability(host: "alpha", .unreachable("refused"), now: t1)
        #expect(store.remoteUnreachableSince["alpha"] == t0)
        #expect(store.remoteReachability["alpha"] == .unreachable("refused"))

        store.noteRemoteReachability(host: "alpha", .reachable, now: t1)
        #expect(store.remoteUnreachableSince["alpha"] == nil)
        store.noteRemoteReachability(host: "alpha", .unreachable("timed out"), now: t2)
        #expect(store.remoteUnreachableSince["alpha"] == t2)

        store.clearHost("alpha")
        #expect(store.remoteUnreachableSince["alpha"] == nil)
    }

    // MARK: Check again

    @MainActor private final class Rig {
        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let registry = RemoteHostRegistry(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let supervisor: RemoteMonitorSupervisor

        init() {
            supervisor = RemoteMonitorSupervisor(store: store, registry: registry) { _ in
                (NoMonitor(), nil)
            }
            registry.onChange = { [supervisor] in supervisor.reconcile() }
        }
    }

    private struct NoMonitor: SessionMonitor {
        func start(into store: SessionStore) async {}
    }

    @Test func checkAgainPublishesAnAssessment() async {
        let rig = Rig()
        let host = RemoteHost(alias: "devbox", watchAs: .loginUser)
        rig.registry.upsert(host)
        let user = Self.probe(
            processes: [Self.process("claude", user: "dev"), Self.process("codex", user: "root")],
            tools: ["claude"], installed: ["claude"])
        var asked: [String] = []
        rig.supervisor.prober = { alias in
            asked.append(alias)
            return (user, nil, nil)
        }
        #expect(rig.supervisor.assessments[host.id] == nil)

        await rig.supervisor.checkAgain(hostID: host.id)

        #expect(asked == ["devbox"])
        let expected = HostAssessment.assess(user: user, root: nil, failure: nil, watchAs: .loginUser)
        #expect(rig.supervisor.assessments[host.id] == expected)
        #expect(rig.supervisor.assessments[host.id]?.hiddenSessions == 1)
        let check = rig.supervisor.checks[host.id]
        #expect(check?.loginUser == "dev")
        #expect(check?.hiddenUsers == ["root"])
        #expect(check?.tools == [.claudeCode])
        #expect(rig.supervisor.checking.isEmpty)
    }

    @Test func checkIsForgottenWhenItNoLongerApplies() async {
        let rig = Rig()
        let host = RemoteHost(alias: "devbox", watchAs: .loginUser)
        rig.registry.upsert(host)
        rig.supervisor.prober = { _ in (Self.probe(), nil, nil) }
        await rig.supervisor.checkAgain(hostID: host.id)
        #expect(rig.supervisor.assessments[host.id] != nil)

        // Judged for the old pick, so it says nothing about the new one.
        var changed = host
        changed.watchAs = .everyUser
        rig.registry.upsert(changed)
        #expect(rig.supervisor.assessments[host.id] == nil)

        await rig.supervisor.checkAgain(hostID: host.id)
        rig.supervisor.forgetCheck(hostID: host.id)
        #expect(rig.supervisor.assessments[host.id] == nil)

        await rig.supervisor.checkAgain(hostID: host.id)
        rig.registry.remove(id: host.id)
        #expect(rig.supervisor.assessments[host.id] == nil)
    }

    @Test func checkAllAgainRunsAtMostSixAtOnce() async {
        let rig = Rig()
        for n in 0..<9 { rig.registry.upsert(RemoteHost(alias: "host\(n)")) }
        var inFlight = 0, peak = 0
        rig.supervisor.prober = { _ in
            inFlight += 1
            peak = max(peak, inFlight)
            try? await Task.sleep(for: .milliseconds(20))
            inFlight -= 1
            return (nil, nil, .timedOut)
        }

        await rig.supervisor.checkAllAgain()

        #expect(peak == ProbeRunner.maxConcurrent)
        #expect(rig.supervisor.assessments.count == 9)
        #expect(rig.supervisor.assessments.values.allSatisfy { $0.status == .cantConnect(.timedOut) })
    }
}
