import Foundation
import Testing
@testable import SwarmBar

/// Holds a fake's work until the test lets it go, so a test can act while
/// a probe is in flight.
@MainActor
final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    var waiting: Int { waiters.count }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    /// Lets the main actor run until something is held here.
    func held(count: Int = 1) async {
        while waiting < count { await Task.yield() }
    }
}

/// Stands in for ssh, the probe and the helper. Every host, user and path
/// here is made up. Plans come from the real SetupPlanner, so the model is
/// tested against the plans it will really get.
@MainActor
final class FakeWizardServices: RemoteWizardServices {
    var aliases: [String] = []
    var skippedGitHosts: [String] = []
    var readProblems: [String] = []
    /// Successive probe answers per alias. The last one repeats.
    var outcomes: [String: [HostAssessmentInput]] = [:]
    /// When set, probes wait here before answering.
    var probeGate: Gate?
    private(set) var candidateCalls = 0
    private(set) var probeAllCalls = 0
    private(set) var probeCalls: [String] = []
    struct PlanCall: Equatable {
        var probeUser: String
        var watchAs: WatchAs
        var loginEUID: Int
        var loginUser: String
        var undo: Bool
    }
    private(set) var planCalls: [PlanCall] = []
    /// What the helper says about a sent change, by path. Default done.
    var applyOutcomes: [String: SetupApplier.StepOutcome] = [:]
    /// Runs after the first change is reported, while the apply is still going.
    var duringApply: (@MainActor () -> Void)?
    private(set) var applied: [(alias: String, plan: SetupPlan)] = []
    let helperVersion = "0.2.0"
    var helperSHA256: String? = String(repeating: "ab", count: 32)
    /// Thrown by plan when set, standing in for a planning failure.
    var planError: (any Error)?

    func candidates() async -> HostCandidateList {
        candidateCalls += 1
        return HostCandidateList(aliases: aliases, skippedGitHosts: skippedGitHosts, readProblems: readProblems)
    }

    private func next(_ alias: String) -> HostAssessmentInput {
        guard var queue = outcomes[alias], let first = queue.first else {
            return (nil, nil, .timedOut)
        }
        if queue.count > 1 {
            queue.removeFirst()
            outcomes[alias] = queue
        }
        return first
    }

    func probe(_ alias: String) async -> HostAssessmentInput {
        probeCalls.append(alias)
        if let probeGate { await probeGate.wait() }
        return next(alias)
    }

    func probeAll(_ aliases: [String]) -> AsyncStream<(String, HostAssessmentInput)> {
        probeAllCalls += 1
        probeCalls += aliases
        let gate = probeGate
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                if let gate { await gate.wait() }
                for alias in aliases { continuation.yield((alias, self.next(alias))) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func plan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int, loginUser: String) throws -> SetupPlan {
        planCalls.append(PlanCall(probeUser: probe.user, watchAs: watchAs, loginEUID: loginEUID,
                                  loginUser: loginUser, undo: false))
        if let planError { throw planError }
        return try SetupPlanner.plan(probe: probe, watchAs: watchAs, bundled: SetupPlannerTests.bridges,
                                     kimiEvents: [:], loginEUID: loginEUID, loginUser: loginUser)
    }

    func undoPlan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int, loginUser: String) throws -> SetupPlan {
        planCalls.append(PlanCall(probeUser: probe.user, watchAs: watchAs, loginEUID: loginEUID,
                                  loginUser: loginUser, undo: true))
        return try SetupPlanner.undoPlan(probe: probe, watchAs: watchAs, loginEUID: loginEUID, loginUser: loginUser)
    }

    /// Behaves like SetupApplier: unsent changes report themselves, and a
    /// change whose dependency did not end done is not made.
    func apply(
        _ plan: SetupPlan, alias: String, progress: @escaping @MainActor (Int, SetupApplier.StepOutcome) -> Void
    ) async {
        applied.append((alias, plan))
        var outcomes: [SetupApplier.StepOutcome] = []
        for change in plan.changes {
            let outcome: SetupApplier.StepOutcome
            switch change.action {
            case .byHand: outcome = .byHand
            case .skipped: outcome = .skipped
            case .write, .remove:
                if change.dependsOn.contains(where: { outcomes[$0] != .done }) {
                    outcome = .failed(SetupApplier.dependencyFailed)
                } else {
                    outcome = applyOutcomes[change.path] ?? .done
                }
            }
            outcomes.append(outcome)
            progress(outcomes.count - 1, outcome)
            if outcomes.count == 1 { duringApply?() }
            await Task.yield()
        }
    }
}

@Suite("Remote wizard model")
@MainActor
struct RemoteWizardModelTests {
    private let defaults = UserDefaults(suiteName: "test-\(UUID())")!
    private let services = FakeWizardServices()

    private func model() -> (RemoteWizardModel, RemoteHostRegistry) {
        let registry = RemoteHostRegistry(defaults: defaults)
        return (RemoteWizardModel(services: services, registry: registry), registry)
    }

    // MARK: Synthetic probes

    static func process(_ comm: String, user: String = "u") -> RemoteProcessRecord {
        RemoteProcessRecord(
            pid: 100, ppid: 1, user: user, comm: comm, args: comm, cwd: "/home/u/work", tty: "pts/1",
            pane: nil, open: [], openFailed: false, screen: nil)
    }

    static func probe(
        _ hostname: String, user: String = "u", sudo: Bool = false, homes: [String: String] = ["/home/u": "u"],
        processes: [RemoteProcessRecord] = [], tools: [String] = [], installed: [String] = [],
        configs: [String: [ProbeResult.ConfigFile]] = [:], bridges: [String: [ProbeResult.BridgeFile]]? = nil,
        helper: [ProbeResult.HelperFile] = []
    ) -> ProbeResult {
        ProbeResult(
            alias: hostname, protocolVersion: 3, system: "Linux", python: "3.12.3", hostname: hostname,
            user: user, euid: user == "root" ? 0 : 1000, sudoOK: sudo,
            homes: homes.keys.sorted().map { RemoteHome(path: $0, user: homes[$0]!) },
            processes: processes,
            tools: Dictionary(uniqueKeysWithValues: homes.keys.map { ($0, tools) }),
            installed: Dictionary(uniqueKeysWithValues: homes.keys.map { ($0, installed) }),
            configs: configs, bridges: bridges, helper: helper)
    }

    static let settings = "/home/u/.claude/settings.json"

    /// Claude running as the login user, its hooks not in yet: two
    /// changes, the hook script then the settings file that names it.
    static func needsSetup(_ host: String) -> HostAssessmentInput {
        (probe(host, processes: [process("claude")], tools: ["claude"],
               configs: ["/home/u": [SetupPlannerTests.config("claude", settings, "{}\n")]]), nil, nil)
    }

    static func ready(_ host: String) -> HostAssessmentInput {
        (probe(host, processes: [process("claude")], tools: ["claude"], installed: ["claude"]), nil, nil)
    }

    static func idle(_ host: String) -> HostAssessmentInput {
        (probe(host), nil, nil)
    }

    /// Codex runs as root, the login user has no passwordless sudo, so the
    /// user has to pick how to watch it.
    static func rootAgents(_ host: String) -> HostAssessmentInput {
        (probe(host, processes: [process("codex", user: "root")], tools: ["claude"],
               configs: ["/home/u": [SetupPlannerTests.config("claude", settings, "{}\n")]]), nil, nil)
    }

    private func row(_ model: RemoteWizardModel, _ alias: String) throws -> RemoteWizardModel.Row {
        try #require(model.rows.first { $0.id == alias })
    }

    // MARK: The brief's cases

    @Test func nothingProbesBeforeLookForHosts() async {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        let (model, _) = model()
        #expect(model.step == .intro)
        #expect(services.candidateCalls == 0)
        #expect(services.probeCalls.isEmpty)
        #expect(model.rows.isEmpty)
        await model.lookForHosts()
        #expect(services.candidateCalls == 1)
        #expect(services.probeCalls == ["alpha"])
        #expect(model.step == .pick)
    }

    @Test func hostsWithAgentsStartChecked() async throws {
        services.aliases = ["alpha", "beta"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "beta": [Self.idle("beta")]]
        let (model, _) = model()
        await model.lookForHosts()
        #expect(try row(model, "alpha").isChecked)
        #expect(try !row(model, "beta").isChecked)
        #expect(model.rows.allSatisfy { !$0.isChecking })
        #expect(try row(model, "beta").assessment?.summary == HostAssessment.noAgents)
        #expect(model.watchAs["alpha"] == .loginUser)
    }

    @Test func cantConnectRowsCannotBeChecked() async throws {
        services.aliases = ["alpha", "beta"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "beta": [(nil, nil, .needsPassword)]]
        let (model, _) = model()
        await model.lookForHosts()
        #expect(try row(model, "beta").assessment?.status == .cantConnect(.needsPassword))
        #expect(try !row(model, "beta").isChecked)
        model.setChecked("beta", true)
        #expect(try !row(model, "beta").isChecked)
        model.setChecked("alpha", false)
        #expect(try !row(model, "alpha").isChecked)
    }

    @Test func readyHostsSkipSetup() async throws {
        services.aliases = ["alpha", "beta"]
        services.outcomes = ["alpha": [Self.ready("alpha")], "beta": [Self.needsSetup("beta")]]
        let (model, registry) = model()
        await model.lookForHosts()
        #expect(try row(model, "alpha").isChecked)
        #expect(model.hostsToSetUp.map(\.id) == ["beta"])
        await model.continueFromPick()
        #expect(model.step == .setup(hostIndex: 0))
        #expect(model.setupAliases == ["beta"])
        #expect(model.currentAlias == "beta")
        // Ready is registered all the same, so its sessions show at once.
        #expect(Set(registry.hosts.map(\.alias)) == ["alpha", "beta"])
    }

    @Test func titleCountsHostsNeedingSetup() async {
        services.aliases = ["alpha", "beta", "devbox"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "beta": [Self.needsSetup("beta")],
                             "devbox": [Self.needsSetup("devbox")]]
        let (model, _) = model()
        await model.lookForHosts()
        #expect(model.primaryTitle == "Set up 3 hosts")
        model.setChecked("alpha", false)
        model.setChecked("beta", false)
        #expect(model.primaryTitle == "Set up 1 host")
        model.setChecked("devbox", false)
        #expect(model.primaryTitle == "Done")
    }

    @Test func pickingWatchAsReassesses() async throws {
        services.aliases = ["devbox"]
        services.outcomes = ["devbox": [Self.rootAgents("devbox")]]
        let (model, _) = model()
        await model.lookForHosts()
        #expect(model.watchAs["devbox"] == nil)
        #expect(try row(model, "devbox").assessment?.status
            == .needsSetup([HostAssessment.pickReason, "Claude Code approvals not set up"]))

        model.watchAs["devbox"] = .loginUser
        let mine = try #require(try row(model, "devbox").assessment)
        #expect(mine.status == .needsSetup(["Claude Code approvals not set up"]))
        #expect(mine.hiddenSessions == 1)

        model.watchAs["devbox"] = .everyUser
        #expect(try row(model, "devbox").assessment?.status == .needsSetup([HostAssessment.sudoRuleReason]))
        // No root view can be taken without sudo or root's helper, so
        // nothing went back to the host.
        #expect(services.probeCalls == ["devbox"])
    }

    @Test func letSwarmBarDoItUnavailableWithoutSudoForEveryUser() async {
        services.aliases = ["alpha", "devbox"]
        let sudoHost = Self.probe("alpha", sudo: true, processes: [Self.process("claude", user: "root")])
        let rootView = Self.probe("alpha", user: "root", sudo: true, homes: ["/root": "root"],
                                  processes: [Self.process("claude", user: "root")], tools: ["claude"])
        services.outcomes = ["devbox": [Self.rootAgents("devbox")], "alpha": [(sudoHost, rootView, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        model.watchAs["devbox"] = .everyUser
        #expect(!model.canLetSwarmBarDoIt("devbox"))
        model.watchAs["devbox"] = .loginUser
        #expect(model.canLetSwarmBarDoIt("devbox"))
        // Passwordless sudo is what lets SwarmBar make every user's changes.
        #expect(model.watchAs["alpha"] == .everyUser)
        #expect(model.canLetSwarmBarDoIt("alpha"))

        model.watchAs["devbox"] = .everyUser
        await model.continueFromPick()
        #expect(model.currentAlias == "alpha")
        #expect(model.path["alpha"] == .swarmBar)
        model.skipHost()
        #expect(model.currentAlias == "devbox")
        #expect(model.path["devbox"] == .command)
    }

    @Test func changedFileStopsOnlyThatFile() async throws {
        let kimi = "/home/u/.kimi-code/config.toml"
        let opencode = "/home/u/.config/opencode/opencode.json"
        let kimiScript = SetupPlanner.kimiScript(home: "/home/u")
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [(Self.probe(
            "alpha", processes: [Self.process("claude")], tools: ["claude", "kimi", "opencode"],
            configs: ["/home/u": [SetupPlannerTests.config("claude", Self.settings, "{}\n"),
                                  SetupPlannerTests.config("kimi", kimi, "[providers]\n"),
                                  SetupPlannerTests.config("opencode", opencode, "{}\n")]]), nil, nil)]]
        // The Kimi hook script changed on the host since the probe read it.
        services.applyOutcomes = [kimiScript: .changed]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        let plan = try #require(model.plan(for: "alpha"))
        func index(_ path: String) throws -> Int { try #require(plan.changes.firstIndex { $0.path == path }) }
        #expect(plan.changes.count == 6)
        #expect(plan.changes[try index(kimi)].dependsOn == [try index(kimiScript)])

        await model.makeChanges()
        #expect(services.applied.map(\.alias) == ["alpha"])
        // Only the changed file, and the config that would name it, are left.
        var expected = Dictionary(uniqueKeysWithValues: plan.changes.indices.map {
            ($0, SetupApplier.StepOutcome.done)
        })
        expected[try index(kimiScript)] = .changed
        expected[try index(kimi)] = .failed(SetupApplier.dependencyFailed)
        #expect(model.progress == expected)
        // Checked again, and still not Ready, so the host stays put with its
        // progress on show.
        #expect(services.probeCalls == ["alpha", "alpha"])
        let status = try #require(try row(model, "alpha").assessment?.status)
        #expect(status != .ready)
        #expect(model.step == .applying(hostIndex: 0))
        #expect(model.currentAlias == "alpha")
    }

    @Test func skippedHostIsStillWatchedAsChosen() async throws {
        services.aliases = ["alpha", "devbox"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "devbox": [Self.rootAgents("devbox")]]
        let (model, registry) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        #expect(model.currentAlias == "alpha")
        model.skipHost()
        #expect(model.currentAlias == "devbox")
        model.watchAs["devbox"] = .everyUser
        model.skipHost()
        #expect(model.step == .done)
        let devbox = try #require(registry.hosts.first { $0.alias == "devbox" })
        #expect(devbox.watchAs == .everyUser)
        #expect(registry.hosts.first { $0.alias == "alpha" }?.watchAs == .loginUser)
    }

    @Test func finishingRegistersHosts() async throws {
        services.aliases = ["alpha", "beta", "devbox"]
        services.outcomes = [
            "alpha": [Self.ready("alpha")],
            "beta": [Self.needsSetup("beta"), Self.ready("beta")],
            "devbox": [Self.idle("devbox")],
        ]
        let (model, registry) = model()
        await model.lookForHosts()
        // Monitoring starts as soon as the pick is made.
        await model.continueFromPick()
        #expect(Set(registry.hosts.map(\.alias)) == ["alpha", "beta"])
        await model.makeChanges()
        #expect(model.step == .done)
        #expect(try row(model, "beta").assessment?.status == .ready)
        let hosts = registry.hosts.sorted { $0.alias < $1.alias }
        #expect(hosts.map(\.alias) == ["alpha", "beta"])
        #expect(hosts.map(\.watchAs) == [.loginUser, .loginUser])
        #expect(hosts.map(\.displayName) == ["alpha", "beta"])
    }

    // MARK: Controller rulings

    @Test func duplicateHostnamesCollapse() async {
        services.aliases = ["alpha", "alpha.ts", "beta"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "alpha.ts": [Self.needsSetup("alpha")],
                             "beta": [Self.idle("beta")]]
        let (model, _) = model()
        await model.lookForHosts()
        #expect(model.rows.map(\.id) == ["alpha", "beta"])
    }

    @Test func pickingEveryUserLooksAgainWhenRootCanBeSeen() async throws {
        services.aliases = ["alpha"]
        let user = Self.probe("alpha", sudo: true, processes: [Self.process("claude", user: "root")])
        let root = Self.probe("alpha", user: "root", sudo: true, homes: ["/root": "root"],
                              processes: [Self.process("claude", user: "root")], tools: ["claude"],
                              installed: ["claude"])
        services.outcomes = ["alpha": [(user, nil, .timedOut), (user, root, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        #expect(model.watchAs["alpha"] == .everyUser)
        #expect(try row(model, "alpha").assessment?.status == .cantConnect(.timedOut))
        model.watchAs["alpha"] = .loginUser
        #expect(try row(model, "alpha").assessment?.status == .ready)
        #expect(services.probeCalls == ["alpha"])
        model.watchAs["alpha"] = .everyUser
        await model.waitForChecks()
        #expect(services.probeCalls == ["alpha", "alpha"])
        #expect(try row(model, "alpha").assessment?.status == .ready)
        #expect(try !row(model, "alpha").isChecking)
    }

    @Test func startSetUpOpensAtStepThreeAfterProbing() async throws {
        let (model, registry) = model()
        registry.upsert(RemoteHost(alias: "beta", watchAs: .loginUser))
        services.outcomes = ["beta": [Self.needsSetup("beta")]]
        await model.startSetUp(alias: "beta")
        #expect(services.candidateCalls == 0)
        #expect(services.probeCalls == ["beta"])
        #expect(model.step == .setup(hostIndex: 0))
        #expect(model.mode == .setUp)
        #expect(model.currentAlias == "beta")
        #expect(model.watchAs["beta"] == .loginUser)
        #expect(model.plan(for: "beta")?.changes.count == 2)
        #expect(registry.hosts.count == 1)
    }

    @Test func startUndoPlansTheUndoAndFinishesWhenNothingIsLeft() async throws {
        let (model, registry) = model()
        registry.upsert(RemoteHost(alias: "beta", watchAs: .loginUser))
        let script = SetupPlanner.claudeScript(home: "/home/u")
        let wired = try ClaudeHookTransform.install("{}\n", scriptPath: script, family: .remote)
        let before = Self.probe(
            "beta", processes: [Self.process("claude")], tools: ["claude"], installed: ["claude"],
            configs: ["/home/u": [SetupPlannerTests.config("claude", Self.settings, wired)]],
            bridges: ["/home/u": [.init(path: script, sha256: String(repeating: "e", count: 64))]])
        let after = Self.probe(
            "beta", processes: [Self.process("claude")], tools: ["claude"],
            configs: ["/home/u": [SetupPlannerTests.config("claude", Self.settings, "{}\n")]],
            bridges: ["/home/u": []])
        services.outcomes = ["beta": [(before, nil, nil), (after, nil, nil)]]
        await model.startUndo(alias: "beta")
        #expect(model.mode == .undo)
        #expect(model.step == .setup(hostIndex: 0))
        let plan = try #require(model.plan(for: "beta"))
        #expect(plan.changes.map(\.path) == [Self.settings, script])
        #expect(plan.changes.last?.action == .remove)
        #expect(services.planCalls.last?.undo == true)
        #expect(model.canLetSwarmBarDoIt("beta"))
        #expect(model.path["beta"] == .swarmBar)
        await model.makeChanges()
        #expect(model.step == .done)
        // Undoing is not removing: the host is still watched.
        #expect(registry.hosts.map(\.alias) == ["beta"])
    }

    @Test func narrowRuleHostIsReplannedAfterTheCommandRuns() async throws {
        services.aliases = ["devbox"]
        let withRule = Self.probe(
            "devbox", processes: [Self.process("codex", user: "root")], tools: ["claude"],
            configs: ["/home/u": [SetupPlannerTests.config("claude", Self.settings, "{}\n")]],
            helper: [.init(path: HelperLaunch.rootHelperPath, sha256: nil)])
        let rootView = Self.probe(
            "devbox", user: "root", sudo: true, homes: ["/root": "root", "/home/u": "u"],
            processes: [Self.process("codex", user: "root")], tools: ["claude"],
            configs: ["/root": [SetupPlannerTests.config("claude", "/root/.claude/settings.json", "{}\n")],
                      "/home/u": [SetupPlannerTests.config("claude", Self.settings, "{}\n")]])
        services.outcomes = ["devbox": [Self.rootAgents("devbox"), (withRule, rootView, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        model.watchAs["devbox"] = .everyUser
        await model.continueFromPick()
        let partial = try #require(model.plan(for: "devbox"))
        #expect(partial.isPartial)
        #expect(model.path["devbox"] == .command)
        #expect(!model.sentChanges(for: "devbox").map(\.path).contains("/root/.claude/settings.json"))

        await model.confirmPastedOrRan()
        let full = try #require(model.plan(for: "devbox"))
        #expect(!full.isPartial)
        #expect(full.changes.map(\.path).contains("/root/.claude/settings.json"))
        #expect(model.step == .setup(hostIndex: 0))
        #expect(try row(model, "devbox").assessment?.status != .ready)
        // Root's view plans, but the login user is who runs the command.
        #expect(services.planCalls.last == .init(probeUser: "root", watchAs: .everyUser, loginEUID: 1000,
                                                  loginUser: "u", undo: false))
    }

    @Test func everyUserWarningShownWhenTheSudoRuleIsPlanned() async {
        services.aliases = ["devbox"]
        services.outcomes = ["devbox": [Self.rootAgents("devbox")]]
        let (model, _) = model()
        await model.lookForHosts()
        model.watchAs["devbox"] = .everyUser
        await model.continueFromPick()
        #expect(model.plan(for: "devbox")?.sudoersUser == "u")
        #expect(model.everyUserWarning(for: "devbox") == SetupCommand.everyUserWarning(user: "u"))
        model.watchAs["devbox"] = .loginUser
        #expect(model.plan(for: "devbox")?.sudoersUser == nil)
        #expect(model.everyUserWarning(for: "devbox") == nil)
    }

    @Test func handEditsAreListedAndNeverSent() async throws {
        services.aliases = ["alpha"]
        let unreadable = ProbeResult.ConfigFile(tool: "claude", path: Self.settings, sha256: nil, text: nil)
        services.outcomes = ["alpha": [(Self.probe("alpha", processes: [Self.process("claude")], tools: ["claude"],
                                                   configs: ["/home/u": [unreadable]]), nil, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        let edits = model.handEdits(for: "alpha")
        #expect(edits.count == 1)
        #expect(edits.first?.hasPrefix("Edit by hand: SwarmBar couldn't read \(Self.settings).") == true)
        #expect(!model.sentChanges(for: "alpha").map(\.path).contains(Self.settings))
        await model.makeChanges()
        let index = try #require(model.plan(for: "alpha")?.changes.firstIndex { $0.path == Self.settings })
        #expect(model.progress[index] == .byHand)
    }

    @Test func aliasTheRegistryRefusesIsMarked() async throws {
        services.aliases = ["-x", "alpha"]
        services.outcomes = ["-x": [Self.needsSetup("devbox")], "alpha": [Self.needsSetup("alpha")]]
        let (model, registry) = model()
        await model.lookForHosts()
        #expect(try row(model, "-x").isChecked)
        await model.continueFromPick()
        #expect(try row(model, "-x").problem == "This host name can't be used.")
        #expect(registry.hosts.map(\.alias) == ["alpha"])
        #expect(model.setupAliases == ["alpha"])
        #expect(model.currentAlias == "alpha")
    }

    @Test func missingHomeSaysSoInsteadOfPlanning() async throws {
        let (model, registry) = model()
        registry.upsert(RemoteHost(alias: "alpha", watchAs: .loginUser))
        services.outcomes = ["alpha": [(Self.probe("alpha", homes: [:], processes: [Self.process("claude")]), nil, nil)]]
        await model.startSetUp(alias: "alpha")
        #expect(model.step == .setup(hostIndex: 0))
        #expect(model.plan(for: "alpha") == nil)
        #expect(try row(model, "alpha").problem == "Couldn't find a home folder for u on this host.")
        #expect(!model.canLetSwarmBarDoIt("alpha"))
    }

    @Test func commandAndPromptComeFromThePlan() async throws {
        services.aliases = ["devbox"]
        services.outcomes = ["devbox": [Self.rootAgents("devbox")]]
        let (model, _) = model()
        await model.lookForHosts()
        model.watchAs["devbox"] = .everyUser
        await model.continueFromPick()
        let command = try #require(try model.command(for: "devbox")?.get())
        #expect(command.contains("sudo python3 -B"))
        #expect(command.contains("/v0.2.0/swarmbar-helper.py"))
        let prompt = try #require(model.prompt(for: "devbox"))
        // The narrow rule's plan only reaches the login user's own files,
        // and there is no passwordless sudo to run anything as root.
        #expect(!prompt.text.contains(SetupCommand.runAsRoot))
        #expect(model.pasteOmissions(for: "devbox").isEmpty)
    }

    @Test func promptRunsAsRootOnlyWithPasswordlessSudo() async throws {
        services.aliases = ["alpha"]
        let user = Self.probe("alpha", sudo: true, processes: [Self.process("claude", user: "root")])
        let root = Self.probe("alpha", user: "root", sudo: true, homes: ["/root": "root"],
                              processes: [Self.process("claude", user: "root")], tools: ["claude"])
        services.outcomes = ["alpha": [(user, root, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        let plan = try #require(model.plan(for: "alpha"))
        #expect(plan.useSudo && plan.sudoersUser == nil)
        #expect(try #require(model.prompt(for: "alpha")).text.contains(SetupCommand.runAsRoot))
    }

    @Test func addHostProbesJustThatOne() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.idle("alpha")], "beta": [Self.needsSetup("beta")]]
        let (model, _) = model()
        await model.lookForHosts()
        await model.addHost(alias: "beta")
        #expect(services.probeCalls == ["alpha", "beta"])
        #expect(model.rows.map(\.id) == ["alpha", "beta"])
        #expect(try row(model, "beta").isChecked)
        await model.addHost(alias: "-bad")
        #expect(try row(model, "-bad").problem == "This host name can't be used.")
        #expect(services.probeCalls == ["alpha", "beta"])
    }

    // MARK: Review round 1

    @Test func checkAgainKeepsTicksAndRetriesWhatCouldNotBeChecked() async throws {
        services.aliases = ["alpha", "beta"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")],
                             "beta": [(nil, nil, .timedOut), Self.needsSetup("beta")]]
        let (model, _) = model()
        await model.lookForHosts()
        #expect(try !row(model, "beta").isChecked)
        model.setChecked("alpha", false)
        await model.checkAgain()
        #expect(services.probeAllCalls == 2)
        #expect(try row(model, "beta").assessment?.status == .needsSetup(["Claude Code approvals not set up"]))
        #expect(try row(model, "beta").isChecked)
        #expect(try !row(model, "alpha").isChecked)
        #expect(model.step == .pick)
    }

    @Test func doubleTapOnLookForHostsStartsOneStream() async {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        let gate = Gate()
        services.probeGate = gate
        let (model, _) = model()
        let first = Task { await model.lookForHosts() }
        await gate.held()
        #expect(model.isProbing)
        await model.lookForHosts()
        #expect(services.candidateCalls == 1)
        #expect(services.probeAllCalls == 1)
        gate.open()
        await first.value
        #expect(model.step == .pick)
        #expect(!model.isProbing)
        #expect(model.rows.map(\.id) == ["alpha"])
    }

    @Test func actionsWaitWhileHostsAreBeingChecked() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "beta": [Self.needsSetup("beta")]]
        let (model, registry) = model()
        await model.lookForHosts()
        let gate = Gate()
        services.probeGate = gate
        let again = Task { await model.checkAgain() }
        await gate.held()
        await model.continueFromPick()
        #expect(model.step == .pick)
        #expect(registry.hosts.isEmpty)
        await model.addHost(alias: "beta")
        #expect(model.rows.map(\.id) == ["alpha"])
        await model.makeChanges()
        #expect(services.applied.isEmpty)
        gate.open()
        await again.value
        await model.continueFromPick()
        #expect(model.step == .setup(hostIndex: 0))
        #expect(registry.hosts.map(\.alias) == ["alpha"])
    }

    @Test func backFromThePickStopsTheProbe() async throws {
        services.aliases = ["alpha", "beta"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "beta": [Self.needsSetup("beta")]]
        let gate = Gate()
        services.probeGate = gate
        let (model, _) = model()
        let look = Task { await model.lookForHosts() }
        await gate.held()
        model.back()
        #expect(model.step == .intro)
        #expect(!model.isProbing)
        await look.value
        #expect(model.step == .intro)
        gate.open()
        await Task.yield()
        #expect(model.rows.allSatisfy { !$0.isChecking && $0.assessment == nil })
    }

    @Test func cancellingMarksHostsNotChecked() async throws {
        services.aliases = ["alpha", "beta"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "beta": [Self.needsSetup("beta")]]
        let gate = Gate()
        services.probeGate = gate
        let (model, _) = model()
        let look = Task { await model.lookForHosts() }
        await gate.held()
        model.cancel()
        await look.value
        #expect(model.rows.map(\.problem) == [RemoteWizardModel.notChecked, RemoteWizardModel.notChecked])
        #expect(model.rows.allSatisfy { !$0.isChecking && !$0.isChecked })
        #expect(!model.isProbing)
        gate.open()
    }

    @Test func callerCancellationStopsTheProbeToo() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        let gate = Gate()
        services.probeGate = gate
        let (model, _) = model()
        let look = Task { await model.lookForHosts() }
        await gate.held()
        look.cancel()
        await look.value
        #expect(!model.isProbing)
        #expect(try row(model, "alpha").problem == RemoteWizardModel.notChecked)
        gate.open()
    }

    @Test func backFromSetupReturnsToThePickButNotMidApply() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        let (model, registry) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        services.duringApply = { model.back() }
        await model.makeChanges()
        #expect(model.step == .applying(hostIndex: 0))
        model.back()
        #expect(model.step == .pick)
        #expect(model.setupAliases.isEmpty)
        #expect(model.progress.isEmpty)
        // Already watched, and going back does not undo that.
        #expect(registry.hosts.map(\.alias) == ["alpha"])
        await model.continueFromPick()
        #expect(model.step == .setup(hostIndex: 0))
    }

    @Test func backDoesNothingWhenOpenedFromSettings() async {
        let (model, registry) = model()
        registry.upsert(RemoteHost(alias: "beta", watchAs: .loginUser))
        services.outcomes = ["beta": [Self.needsSetup("beta")]]
        await model.startSetUp(alias: "beta")
        model.back()
        #expect(model.step == .setup(hostIndex: 0))
    }

    @Test func watchAsChangesAreIgnoredWhileApplying() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        let (model, registry) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        services.duringApply = { model.watchAs["alpha"] = .everyUser }
        await model.makeChanges()
        #expect(model.watchAs["alpha"] == .loginUser)
        #expect(registry.hosts.first?.watchAs == .loginUser)
        #expect(model.plan(for: "alpha")?.watchAs == .loginUser)
    }

    @Test func pickedPathSurvivesAReplanAndADefaultFollowsIt() async throws {
        services.aliases = ["alpha", "devbox"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")], "devbox": [Self.rootAgents("devbox")]]
        let (model, _) = model()
        await model.lookForHosts()
        model.watchAs["devbox"] = .everyUser
        await model.continueFromPick()
        #expect(model.path["alpha"] == .swarmBar)
        model.path["alpha"] = .paste
        await model.confirmPastedOrRan()
        #expect(model.currentAlias == "alpha")
        #expect(model.path["alpha"] == .paste)

        model.skipHost()
        #expect(model.path["devbox"] == .command)
        // Nothing picked here, so the default moves with the plan.
        model.watchAs["devbox"] = .loginUser
        #expect(model.path["devbox"] == .swarmBar)
    }

    @Test func confirmingMovesToTheNextHostOnceReady() async throws {
        services.aliases = ["alpha", "beta"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha"), Self.ready("alpha")],
                             "beta": [Self.needsSetup("beta")]]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        #expect(model.currentAlias == "alpha")
        await model.confirmPastedOrRan()
        #expect(model.step == .setup(hostIndex: 1))
        #expect(model.currentAlias == "beta")
        #expect(try row(model, "alpha").assessment?.status == .ready)
        #expect(model.plan(for: "beta") != nil)
    }

    @Test func aPendingRootViewHoldsChangesAndContinueDropsIt() async throws {
        let (model, registry) = model()
        registry.upsert(RemoteHost(alias: "alpha", watchAs: .loginUser))
        let user = Self.probe("alpha", sudo: true, processes: [Self.process("claude")], tools: ["claude"],
                              configs: ["/home/u": [SetupPlannerTests.config("claude", Self.settings, "{}\n")]])
        let root = Self.probe("alpha", user: "root", sudo: true, homes: ["/root": "root", "/home/u": "u"],
                              processes: [Self.process("claude")], tools: ["claude"])
        services.outcomes = ["alpha": [(user, nil, .timedOut), (user, root, nil)]]
        await model.startSetUp(alias: "alpha")
        #expect(model.canLetSwarmBarDoIt("alpha"))
        let gate = Gate()
        services.probeGate = gate
        model.watchAs["alpha"] = .everyUser
        await gate.held()
        #expect(model.isBusy)
        await model.makeChanges()
        #expect(services.applied.isEmpty)
        gate.open()
        await model.waitForChecks()
        #expect(!model.isBusy)
        #expect(model.plan(for: "alpha")?.changes.contains { $0.path.hasPrefix("/root/") } == true)

        // On the pick, a root view still pending is dropped by Continue.
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [(user, nil, .timedOut), (user, root, nil)]]
        services.probeGate = nil
        await model.lookForHosts()
        model.watchAs["alpha"] = .loginUser
        let second = Gate()
        services.probeGate = second
        model.watchAs["alpha"] = .everyUser
        await second.held()
        await model.continueFromPick()
        #expect(!model.isBusy)
        #expect(try !row(model, "alpha").isChecking)
        second.open()
        await Task.yield()
        #expect(try row(model, "alpha").assessment?.status == .cantConnect(.timedOut))
    }

    @Test func aSuggestionLandsLikeAPick() async throws {
        services.aliases = ["devbox"]
        let user = Self.probe("devbox", sudo: true, processes: [Self.process("codex", user: "root")])
        let root = Self.probe("devbox", user: "root", sudo: true, homes: ["/root": "root"],
                              processes: [Self.process("codex", user: "root")], tools: ["claude"])
        services.outcomes = ["devbox": [Self.rootAgents("devbox"), (user, root, nil)]]
        let (model, registry) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        #expect(registry.hosts.first?.watchAs == .loginUser)
        #expect(model.plan(for: "devbox") == nil)
        // Passwordless sudo appeared, so every user is suggested and taken.
        await model.confirmPastedOrRan()
        #expect(model.watchAs["devbox"] == .everyUser)
        #expect(registry.hosts.first?.watchAs == .everyUser)
        #expect(model.plan(for: "devbox")?.watchAs == .everyUser)
    }

    @Test func candidateListDetailsReachTheModel() async {
        services.aliases = ["alpha"]
        services.skippedGitHosts = ["github.com", "bitbucket.org"]
        services.readProblems = ["Couldn't read ~/.ssh/extra: Permission denied"]
        services.outcomes = ["alpha": [Self.idle("alpha")]]
        let (model, _) = model()
        #expect(model.skippedLine == nil)
        await model.lookForHosts()
        #expect(model.skippedLine == "Skipped: github.com, bitbucket.org (git hosts).")
        #expect(model.configProblems == ["Couldn't read ~/.ssh/extra: Permission denied"])
    }

    @Test func missingHelperAndBridgesSaySo() async throws {
        services.aliases = ["devbox", "alpha"]
        services.helperSHA256 = nil
        services.outcomes = ["devbox": [Self.rootAgents("devbox")], "alpha": [Self.needsSetup("alpha")]]
        let (model, _) = model()
        await model.lookForHosts()
        model.watchAs["devbox"] = .everyUser
        await model.continueFromPick()
        #expect(model.command(for: "devbox") == Result<String, SetupCommand.Unavailable>.failure(.helperMissing))
        #expect(SetupCommand.Unavailable.helperMissing.reason == "SwarmBar's helper is missing from the app.")
        #expect(model.path["devbox"] == .paste)

        services.planError = RemoteWizardError.bridgesMissing
        model.skipHost()
        #expect(model.currentAlias == "alpha")
        #expect(try row(model, "alpha").problem == "SwarmBar's bridge scripts are missing from the app.")
    }

    // MARK: The windows (Task 21)

    @Test func anEarlierLookThatEndsLateLeavesTheNewOneChecking() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        let gate = Gate()
        services.probeGate = gate
        let (model, _) = model()
        let first = Task { await model.lookForHosts() }
        await gate.held()
        model.back()
        let second = Task { await model.lookForHosts() }
        await gate.held(count: 2)
        // The first look's probe was stopped, so it returns now, while the
        // second is still checking. It must not flip the second to the pick.
        await first.value
        #expect(model.step == .checking)
        #expect(model.isProbing)
        gate.open()
        await second.value
        #expect(model.step == .pick)
        #expect(try row(model, "alpha").assessment != nil)
    }

    @Test func backFromSetupClearsPlanningProblems() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        let (model, _) = model()
        await model.lookForHosts()
        services.planError = RemoteWizardError.bridgesMissing
        await model.continueFromPick()
        #expect(try row(model, "alpha").problem == "SwarmBar's bridge scripts are missing from the app.")
        model.back()
        #expect(model.step == .pick)
        #expect(try row(model, "alpha").problem == nil)
        // Checkable again, since nothing is wrong with the host itself.
        model.setChecked("alpha", false)
        model.setChecked("alpha", true)
        #expect(try row(model, "alpha").isChecked)
    }

    @Test func backFromSetupKeepsAnUnusableAlias() async throws {
        services.aliases = ["-x", "alpha"]
        services.outcomes = ["-x": [Self.needsSetup("devbox")], "alpha": [Self.needsSetup("alpha")]]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        model.back()
        #expect(try row(model, "-x").problem == RemoteWizardModel.unusableAlias)
    }

    @Test func backClosesTheWindowOnlyWhenOpenedFromSettings() async throws {
        let (model, registry) = model()
        registry.upsert(RemoteHost(alias: "beta", watchAs: .loginUser))
        services.aliases = ["beta"]
        services.outcomes = ["beta": [Self.needsSetup("beta")]]
        #expect(!model.openedAtSetup)
        await model.startSetUp(alias: "beta")
        #expect(model.openedAtSetup)
        await model.lookForHosts()
        #expect(!model.openedAtSetup)
        await model.startUndo(alias: "beta")
        #expect(model.openedAtSetup)
        await model.open(.fresh)
        #expect(!model.openedAtSetup)
    }

    @Test func openingDispatchesToTheEntryPoint() async throws {
        let (model, registry) = model()
        registry.upsert(RemoteHost(alias: "beta", watchAs: .loginUser))
        services.aliases = ["beta"]
        services.outcomes = ["beta": [Self.needsSetup("beta")]]
        await model.open(.setUp(alias: "beta"))
        #expect(model.step == .setup(hostIndex: 0))
        #expect(model.mode == .setUp)
        await model.open(.undo(alias: "beta"))
        #expect(model.mode == .undo)
        await model.open(.fresh)
        #expect(model.step == .intro)
        #expect(model.rows.isEmpty)
        #expect(model.mode == .setUp)
        // Opening never reaches out by itself: only the entry points probe.
        #expect(services.candidateCalls == 0)
    }

    @Test func openingFreshLeavesChangesBeingMadeOnShow() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        var reopened: RemoteWizardModel.Step?
        services.duringApply = {
            Task { @MainActor in
                await model.open(.fresh)
                reopened = model.step
            }
        }
        await model.makeChanges()
        await Task.yield()
        #expect(reopened == .applying(hostIndex: 0))
    }

    @Test func progressReadsAgainstThePlanThatWasApplied() async throws {
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        services.applyOutcomes = [Self.settings: .changed]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        let applied = try #require(model.plan(for: "alpha"))
        #expect(model.appliedPlan == nil)
        await model.makeChanges()
        #expect(model.step == .applying(hostIndex: 0))
        #expect(model.appliedPlan == applied)
        #expect(model.progress.count == applied.changes.count)
        model.back()
        #expect(model.appliedPlan == nil)
    }

    @Test func changesAreGroupedByToolWithKeystrokeToolsSaid() async throws {
        let kimi = "/home/u/.kimi-code/config.toml"
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [(Self.probe(
            "alpha", processes: [Self.process("claude"), Self.process("grok")],
            tools: ["claude", "kimi", "codex"],
            configs: ["/home/u": [SetupPlannerTests.config("claude", Self.settings, "{}\n"),
                                  SetupPlannerTests.config("kimi", kimi, "[providers]\n")]]), nil, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        let plan = try #require(model.plan(for: "alpha"))
        let groups = model.changeGroups(for: "alpha")
        #expect(groups.map(\.title) == ["Claude Code", "Codex", "Kimi Code", "Grok Build"])
        #expect(groups[0].lines == plan.changes.filter { $0.tool == .claudeCode }.map(\.description))
        #expect(groups[1].lines == [RemoteWizardModel.nothingToInstall])
        #expect(groups[3].lines == [RemoteWizardModel.nothingToInstall])
        #expect(groups.flatMap(\.lines).count == plan.changes.count + 2)
        #expect(model.changeGroups(for: "nobody").isEmpty)
    }

    @Test func handEditsStayOutOfTheGroups() async throws {
        services.aliases = ["alpha"]
        let unreadable = ProbeResult.ConfigFile(tool: "claude", path: Self.settings, sha256: nil, text: nil)
        services.outcomes = ["alpha": [(Self.probe("alpha", processes: [Self.process("claude")], tools: ["claude"],
                                                   configs: ["/home/u": [unreadable]]), nil, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        let edits = model.handEdits(for: "alpha")
        #expect(edits.count == 1)
        #expect(!model.changeGroups(for: "alpha").flatMap(\.lines).contains(edits[0]))
    }

    @Test func theCommandAlsoListsTheHelperAndTheSudoRule() async throws {
        services.aliases = ["devbox"]
        services.outcomes = ["devbox": [Self.rootAgents("devbox")]]
        let (model, _) = model()
        await model.lookForHosts()
        model.watchAs["devbox"] = .everyUser
        await model.continueFromPick()
        let plan = try #require(model.plan(for: "devbox"))
        #expect(plan.installHelper && plan.sudoersUser == "u")
        let shared = try #require(model.changeGroups(for: "devbox", forCommand: true).last)
        #expect(shared.title == "Shared")
        #expect(shared.lines == [
            "Install SwarmBar's helper at \(HelperLaunch.rootHelperPath)",
            "Let u run SwarmBar's helper as root, in /etc/sudoers.d/swarmbar",
        ])
        #expect(!model.changeGroups(for: "devbox").contains { $0.title == "Shared" })
        #expect(RemoteWizardModel.sudoersLine(user: "u")
            == "u ALL=(root) NOPASSWD: \(HelperLaunch.rootHelperPath)")
    }

    @Test func watchContextSaysWhoRunsWhat() async throws {
        services.aliases = ["devbox", "alpha"]
        services.outcomes = ["devbox": [Self.rootAgents("devbox")], "alpha": [Self.needsSetup("alpha")]]
        let (model, _) = model()
        await model.lookForHosts()
        let devbox = try #require(model.watchContext(for: "devbox"))
        #expect(devbox == .init(loginUser: "u", sudoOK: false, otherSessions: 1, otherUsers: ["root"],
                                otherSummary: "1 Codex"))
        #expect(WizardCopy.othersRunAs(devbox) == "The 1 Codex session here runs as root.")
        #expect(WizardCopy.loginLine(devbox)
            == "You log in as u without passwordless sudo, so SwarmBar can't read them yet.")
        #expect(WizardCopy.hiddenLine(devbox) == "1 session runs as root and isn't shown")
        let alpha = try #require(model.watchContext(for: "alpha"))
        #expect(alpha.otherSessions == 0)
        #expect(WizardCopy.othersRunAs(alpha) == nil)
        #expect(WizardCopy.hiddenLine(alpha) == nil)
        #expect(model.watchContext(for: "nobody") == nil)
    }

    @Test func copyCountsReadNaturally() {
        let two = RemoteWizardModel.WatchContext(loginUser: "u", sudoOK: true, otherSessions: 2,
                                                 otherUsers: ["root"], otherSummary: "2 Codex")
        #expect(WizardCopy.othersRunAs(two) == "The 2 Codex sessions here run as root.")
        #expect(WizardCopy.loginLine(two) == "You log in as u with passwordless sudo, so SwarmBar can read them.")
        #expect(WizardCopy.hiddenLine(two) == "2 sessions run as root and aren't shown")
        let mixed = RemoteWizardModel.WatchContext(loginUser: "u", sudoOK: false, otherSessions: 3,
                                                   otherUsers: ["alice", "root"], otherSummary: "2 Codex, 1 Grok Build")
        #expect(WizardCopy.othersRunAs(mixed) == "3 sessions here run as alice, root: 2 Codex, 1 Grok Build.")
        let unknown = RemoteWizardModel.WatchContext(loginUser: "u", sudoOK: false, otherSessions: nil,
                                                     otherUsers: [], otherSummary: "")
        #expect(WizardCopy.othersRunAs(unknown) == nil)
        #expect(WizardCopy.hiddenLine(unknown) == nil)
        #expect(WizardCopy.hosts(1) == "1 host")
        #expect(WizardCopy.hosts(4) == "4 hosts")
        #expect(WizardCopy.sessions(1) == "1 session")
        #expect(WizardCopy.sessions(0) == "0 sessions")
    }

    @Test func sessionsOutsideTmuxAreCountedForKeystrokeTools() async throws {
        let pane = RemotePane(socket: "/tmp/tmux-1000/default", id: "%1")
        func process(_ comm: String, pane: RemotePane?) -> RemoteProcessRecord {
            RemoteProcessRecord(pid: 100, ppid: 1, user: "u", comm: comm, args: comm, cwd: "/home/u/work",
                                tty: "pts/1", pane: pane, open: [], openFailed: false, screen: nil)
        }
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [(Self.probe("alpha", processes: [
            process("kimi", pane: nil), process("claude", pane: nil), process("codex", pane: nil),
            process("codex", pane: nil), process("grok", pane: pane),
        ]), nil, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        // Claude answers over its hook, so tmux does not matter for it.
        #expect(model.notInTmuxLines(for: "alpha") == [
            "2 Codex sessions aren't in tmux: answer them in their terminals",
            "1 Kimi Code session isn't in tmux: answer it in its terminal",
        ])
    }

    @Test func pillsFollowTheAssessment() async throws {
        services.aliases = ["alpha", "beta", "devbox", "gamma"]
        let partial = Self.probe("gamma", processes: [Self.process("claude"), Self.process("codex", user: "root")],
                                 tools: ["claude"], installed: ["claude"])
        services.outcomes = ["alpha": [Self.ready("alpha")], "beta": [Self.needsSetup("beta")],
                             "devbox": [(nil, nil, .needsPassword)], "gamma": [(partial, nil, nil)]]
        let (model, _) = model()
        await model.lookForHosts()
        #expect(model.pill(for: try row(model, "alpha")) == .ready)
        #expect(model.pill(for: try row(model, "beta")) == .needsSetup)
        #expect(model.pill(for: try row(model, "devbox")) == .cantConnect)
        // No pick yet, and agents run as root: the pick is what it needs.
        #expect(model.pill(for: try row(model, "gamma")) == .needsSetup)
        model.watchAs["gamma"] = .loginUser
        #expect(model.pill(for: try row(model, "gamma")) == .partial)
        var broken = try row(model, "beta")
        broken.problem = "Couldn't find a home folder for u on this host."
        #expect(model.pill(for: broken) == .cantContinue)
        broken.problem = RemoteWizardModel.notChecked
        #expect(model.pill(for: broken) == nil)
        broken.problem = nil
        broken.isChecking = true
        #expect(model.pill(for: broken) == nil)
    }

    @Test func watchedRowsAreTheHostsThisRunRegistered() async throws {
        services.aliases = ["alpha", "beta", "devbox"]
        services.outcomes = ["alpha": [Self.ready("alpha")], "beta": [Self.idle("beta")],
                             "devbox": [(nil, nil, .timedOut)]]
        let (model, registry) = model()
        await model.lookForHosts()
        #expect(model.watchedRows.isEmpty)
        await model.continueFromPick()
        #expect(model.step == .done)
        #expect(model.watchedRows.map(\.id) == ["alpha"])
        registry.upsert(RemoteHost(alias: "other", displayName: "alpha"))
        #expect(model.watchedName("alpha") == "alpha")
        #expect(model.helperVersion == "0.2.0")
    }

    @Test func theLauncherBuildsOneModelLateAndHandsEachRequestOnce() async throws {
        var built = 0
        let launcher = RemoteWizardLauncher {
            built += 1
            return RemoteWizardModel(services: services, registry: RemoteHostRegistry(defaults: defaults))
        }
        #expect(built == 0)
        #expect(launcher.takeRequest() == nil)
        launcher.ask(.fresh)
        #expect(launcher.takeRequest() == .fresh)
        #expect(launcher.takeRequest() == nil)
        launcher.ask(.undo(alias: "beta"))
        #expect(launcher.takeRequest() == .undo(alias: "beta"))
        let model = try #require(launcher.model)
        #expect(launcher.model === model)
        #expect(built == 1)
        #expect(RemoteWizardLauncher(makeModel: nil).model == nil)
    }
}

/// The live service's reading of ssh config, on files in a temporary home.
@Suite("Remote wizard candidates")
@MainActor
struct RemoteWizardCandidatesTests {
    private static func resolve(_ alias: String) async -> SSHResolved? {
        switch alias {
        case "github.com": SSHResolved(hostname: "github.com", user: "git", port: 22)
        case "forge": SSHResolved(hostname: "git.example.invalid", user: "git", port: 22)
        default: SSHResolved(hostname: alias + ".example.invalid", user: "u", port: 22)
        }
    }

    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swarmbar-wizard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        return url
    }

    private func read(_ home: URL) async -> HostCandidateList {
        await LiveRemoteWizardServices.readCandidates(
            sshDirectory: home.appendingPathComponent(".ssh"), home: home, resolve: Self.resolve)
    }

    @Test func missingConfigIsNoHostsAndNoProblem() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(await read(home) == HostCandidateList())
    }

    @Test func gitHostsAreSkippedByName() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try "Host alpha github.com forge beta\n".write(
            to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let list = await read(home)
        #expect(list.aliases == ["alpha", "beta"])
        #expect(list.skippedGitHosts == ["github.com", "forge"])
        #expect(list.readProblems.isEmpty)
    }

    @Test func configThatIsNotUTF8IsAProblem() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data([0x48, 0x6f, 0xff, 0xfe, 0x0a]).write(to: home.appendingPathComponent(".ssh/config"))
        let list = await read(home)
        #expect(list.aliases.isEmpty)
        #expect(list.readProblems == ["Couldn't read ~/.ssh/config: it isn't UTF-8 text"])
    }

    @Test func unreadableIncludeIsAProblemAndTheRestStillCounts() async throws {
        let home = try home()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: home.appendingPathComponent(".ssh/extra").path)
            try? FileManager.default.removeItem(at: home)
        }
        try "Include extra\nInclude absent\nHost alpha\n".write(
            to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let extra = home.appendingPathComponent(".ssh/extra")
        try "Host beta\n".write(to: extra, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: extra.path)
        let list = await read(home)
        #expect(list.aliases == ["alpha"])
        // An Include of a file that is not there is ssh's own business.
        #expect(list.readProblems == ["Couldn't read ~/.ssh/extra: Permission denied"])
    }
}
