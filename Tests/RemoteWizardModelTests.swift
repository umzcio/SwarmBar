import Foundation
import Testing
@testable import SwarmBar

/// Stands in for ssh, the probe and the helper. Every host, user and path
/// here is made up. Plans come from the real SetupPlanner, so the model is
/// tested against the plans it will really get.
@MainActor
final class FakeWizardServices: RemoteWizardServices {
    var aliases: [String] = []
    /// Successive probe answers per alias. The last one repeats.
    var outcomes: [String: [HostAssessmentInput]] = [:]
    private(set) var candidateCalls = 0
    private(set) var probeCalls: [String] = []
    struct PlanCall: Equatable {
        var probeUser: String
        var watchAs: WatchAs
        var loginEUID: Int
        var loginUser: String
        var undo: Bool
    }
    private(set) var planCalls: [PlanCall] = []
    /// What apply reports for each sent change, by index. Default done.
    var applyOutcomes: [Int: SetupApplier.StepOutcome] = [:]
    private(set) var applied: [(alias: String, plan: SetupPlan)] = []
    let helperVersion = "0.2.0"
    let helperSHA256: String? = String(repeating: "ab", count: 32)

    func candidates() async -> [String] {
        candidateCalls += 1
        return aliases
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
        return next(alias)
    }

    func probeAll(_ aliases: [String]) -> AsyncStream<(String, HostAssessmentInput)> {
        let results = aliases.map { alias in
            probeCalls.append(alias)
            return (alias, next(alias))
        }
        return AsyncStream { continuation in
            for result in results { continuation.yield(result) }
            continuation.finish()
        }
    }

    func plan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int, loginUser: String) throws -> SetupPlan {
        planCalls.append(PlanCall(probeUser: probe.user, watchAs: watchAs, loginEUID: loginEUID,
                                  loginUser: loginUser, undo: false))
        return try SetupPlanner.plan(probe: probe, watchAs: watchAs, bundled: SetupPlannerTests.bridges,
                                     kimiEvents: [:], loginEUID: loginEUID, loginUser: loginUser)
    }

    func undoPlan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int, loginUser: String) throws -> SetupPlan {
        planCalls.append(PlanCall(probeUser: probe.user, watchAs: watchAs, loginEUID: loginEUID,
                                  loginUser: loginUser, undo: true))
        return try SetupPlanner.undoPlan(probe: probe, watchAs: watchAs, loginEUID: loginEUID, loginUser: loginUser)
    }

    func apply(
        _ plan: SetupPlan, alias: String, progress: @escaping @MainActor (Int, SetupApplier.StepOutcome) -> Void
    ) async {
        applied.append((alias, plan))
        for (index, change) in plan.changes.enumerated() {
            switch change.action {
            case .byHand: progress(index, .byHand)
            case .skipped: progress(index, .skipped)
            case .write, .remove: progress(index, applyOutcomes[index] ?? .done)
            }
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
        services.aliases = ["alpha"]
        services.outcomes = ["alpha": [Self.needsSetup("alpha")]]
        services.applyOutcomes = [1: .changed]
        let (model, _) = model()
        await model.lookForHosts()
        await model.continueFromPick()
        let plan = try #require(model.plan(for: "alpha"))
        #expect(plan.changes.count == 2)
        await model.makeChanges()
        #expect(services.applied.map(\.alias) == ["alpha"])
        #expect(model.progress == [0: .done, 1: .changed])
        // Checked again, and still not Ready, so the host stays put.
        #expect(services.probeCalls == ["alpha", "alpha"])
        #expect(try row(model, "alpha").assessment?.status == .needsSetup(["Claude Code approvals not set up"]))
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
        #expect(prompt.text.contains(SetupCommand.runAsRoot))
        #expect(model.pasteOmissions(for: "devbox").isEmpty)
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
}
