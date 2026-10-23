import Foundation
import Observation

/// One host's probe: the login user's view, root's view when one was taken,
/// and why the probe failed when it did. Exactly what ProbeRunner returns.
typealias HostAssessmentInput = ProbeRunner.Outcome

/// Everything the wizard does that leaves this process: reading ssh config,
/// probing hosts, planning against the bundled bridges, and making changes
/// over ssh. A protocol so the model's tests run on fakes and never start
/// ssh.
@MainActor
protocol RemoteWizardServices: AnyObject {
    /// The aliases worth offering, from ~/.ssh/config, git forges dropped.
    func candidates() async -> [String]
    func probe(_ alias: String) async -> HostAssessmentInput
    /// Probes several hosts at once and yields each as it finishes, so
    /// each row can stop its spinner on its own.
    func probeAll(_ aliases: [String]) -> AsyncStream<(String, HostAssessmentInput)>
    /// `loginEUID` and `loginUser` always come from the login user's own
    /// probe, since `probe` may be root's view, which says nothing about
    /// who will run the setup command.
    func plan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int, loginUser: String) throws -> SetupPlan
    func undoPlan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int, loginUser: String) throws -> SetupPlan
    /// Makes the plan's changes over a one-shot helper channel, reporting
    /// each change's outcome by its index in `plan.changes`.
    func apply(
        _ plan: SetupPlan, alias: String, progress: @escaping @MainActor (Int, SetupApplier.StepOutcome) -> Void
    ) async
    /// The release the setup command downloads the helper from.
    var helperVersion: String { get }
    /// The helper's sha256, which the setup command checks. nil when the
    /// app bundle has no helper, so there is no command to show.
    var helperSHA256: String? { get }
}

/// The remote hosts wizard as a state machine: intro, checking, the pick,
/// one setup step per host that needs one, and done. Views only read it
/// and call its actions, so every path through the flow is unit tested.
///
/// Nothing touches the network until `lookForHosts`, `addHost`,
/// `startSetUp` or `startUndo` is called: the wizard never opens by itself,
/// and opening it must not reach out to anything either.
@MainActor @Observable
final class RemoteWizardModel {
    enum Step: Equatable {
        case intro, checking, pick
        case setup(hostIndex: Int)
        case applying(hostIndex: Int)
        case done
    }

    enum SetupPath: Equatable { case swarmBar, paste, command }

    /// Setting a host up, or undoing its changes from Settings. Both walk
    /// the same steps and offer the same three paths.
    enum Mode: Equatable { case setUp, undo }

    struct Row: Identifiable, Equatable {
        /// The ssh alias, as ssh config spells it.
        let id: String
        var displayName: String
        /// nil until the host's probe comes back.
        var assessment: HostAssessment?
        var isChecked: Bool
        var isChecking: Bool
        /// Why this host can't go on, whatever the assessment says. The
        /// view shows it with "Can't continue".
        var problem: String? = nil
    }

    static let unusableAlias = "This host name can't be used."
    static let planFailed = "SwarmBar couldn't work out the changes for this host."

    static func noHomeMessage(user: String) -> String {
        "Couldn't find a home folder for \(user) on this host."
    }

    private(set) var step: Step = .intro
    private(set) var rows: [Row] = []
    private(set) var mode: Mode = .setUp
    /// Per alias. Starts from each host's suggestion, and stays empty for a
    /// host where the user has to pick. A change reassesses the host from
    /// the probe already taken, and updates the registry once the host is
    /// registered.
    var watchAs: [String: WatchAs] = [:] {
        didSet {
            guard !seeding else { return }
            for alias in Set(oldValue.keys).union(watchAs.keys) where oldValue[alias] != watchAs[alias] {
                watchAsChanged(alias)
            }
        }
    }
    /// Per alias: "Let SwarmBar do it" by default, or the command when that
    /// is unavailable, or the paste when there is no command either.
    var path: [String: SetupPath] = [:]
    /// The current host's changes as the helper reports them, by index in
    /// its plan.
    private(set) var progress: [Int: SetupApplier.StepOutcome] = [:]
    /// The hosts step 3 walks, in order, fixed when it starts so a host
    /// that turns Ready on the way does not shift the count.
    private(set) var setupAliases: [String] = []
    private(set) var plans: [String: SetupPlan] = [:]
    /// True while changes are being made or a host is being checked again
    /// from step 3, when the step actions are ignored.
    private(set) var isWorking = false

    @ObservationIgnored private let services: any RemoteWizardServices
    @ObservationIgnored private let registry: RemoteHostRegistry
    @ObservationIgnored private var inputs: [String: HostAssessmentInput] = [:]
    /// Hosts this run has put in the registry, so a later pick updates them.
    @ObservationIgnored private var registered: Set<String> = []
    /// The path last chosen for a host by default, so a replan may change
    /// a default but never a path the user picked.
    @ObservationIgnored private var defaultPaths: [String: SetupPath] = [:]
    /// Set while the model fills in suggestions itself, which are not a
    /// pick and need no reaction.
    @ObservationIgnored private var seeding = false
    @ObservationIgnored private var checks: [Task<Void, Never>] = []

    init(services: any RemoteWizardServices, registry: RemoteHostRegistry) {
        self.services = services
        self.registry = registry
    }

    // MARK: Steps 1 and 2

    /// Reads ssh config, probes every candidate, and lands on the pick.
    func lookForHosts() async {
        guard !isWorking else { return }
        reset()
        step = .checking
        let aliases = await services.candidates()
        rows = aliases.map {
            Row(id: $0, displayName: RemoteHost.defaultDisplayName(for: $0), assessment: nil,
                isChecked: false, isChecking: true)
        }
        await probe(aliases, setDefaultCheck: Set(aliases))
        collapseRows()
        step = .pick
    }

    /// "Add a host by name". A name ssh could read as an option is never
    /// probed.
    func addHost(alias: String) async {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !rows.contains(where: { $0.id == alias }) else { return }
        let safe = SSHConfigParser.isSafeAlias(alias)
        rows.append(Row(id: alias, displayName: RemoteHost.defaultDisplayName(for: alias), assessment: nil,
                        isChecked: false, isChecking: safe, problem: safe ? nil : Self.unusableAlias))
        guard safe else { return }
        await probe([alias], setDefaultCheck: [alias])
        collapseRows()
    }

    /// Probes every row again. The user's ticks stay, except that a host
    /// which could not be checked before gets the default tick now.
    func checkAgain() async {
        guard !isWorking else { return }
        let aliases = rows.filter { $0.problem != Self.unusableAlias }.map(\.id)
        let uncheckable = Set(rows.filter { !Self.canCheck($0) }.map(\.id))
        await probe(aliases, setDefaultCheck: uncheckable)
        collapseRows()
    }

    func setChecked(_ alias: String, _ checked: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == alias }) else { return }
        rows[index].isChecked = checked && Self.canCheck(rows[index])
    }

    /// Checked rows that still need step 3.
    var hostsToSetUp: [Row] {
        rows.filter { row in
            guard row.isChecked, row.problem == nil, case .needsSetup = row.assessment?.status else { return false }
            return true
        }
    }

    var primaryTitle: String {
        switch hostsToSetUp.count {
        case 0: "Done"
        case 1: "Set up 1 host"
        case let count: "Set up \(count) hosts"
        }
    }

    /// Registers every checked host with its watch-as, so its sessions show
    /// at once, then opens step 3 on the first host that needs it.
    func continueFromPick() async {
        guard step == .pick, !isWorking else { return }
        mode = .setUp
        var queue: [String] = []
        for row in rows where row.isChecked && Self.canCheck(row) {
            guard register(row.id) else {
                setRow(row.id) { $0.problem = Self.unusableAlias }
                continue
            }
            if case .needsSetup = row.assessment?.status { queue.append(row.id) }
        }
        setupAliases = queue
        progress = [:]
        if queue.isEmpty {
            step = .done
        } else {
            step = .setup(hostIndex: 0)
            prepare(queue[0])
        }
    }

    // MARK: Entry points from Settings

    /// "Set up again": step 3 for one registered host, after probing it.
    func startSetUp(alias: String) async {
        await start(alias, mode: .setUp)
    }

    /// "Undo changes": the undo plan for one registered host, offered
    /// through the same three paths.
    func startUndo(alias: String) async {
        await start(alias, mode: .undo)
    }

    private func start(_ alias: String, mode: Mode) async {
        guard !isWorking else { return }
        reset()
        self.mode = mode
        let host = registry.hosts.first { $0.alias == alias }
        let safe = SSHConfigParser.isSafeAlias(alias)
        rows = [Row(id: alias, displayName: host?.displayName ?? RemoteHost.defaultDisplayName(for: alias),
                    assessment: nil, isChecked: true, isChecking: safe, problem: safe ? nil : Self.unusableAlias)]
        if let host {
            registered = [alias]
            seed { watchAs[alias] = host.watchAs }
        }
        setupAliases = [alias]
        if safe {
            step = .checking
            record(alias, await services.probe(alias), setDefaultCheck: false)
        }
        step = .setup(hostIndex: 0)
        prepare(alias)
    }

    // MARK: Step 3

    var currentAlias: String? {
        switch step {
        case .setup(let index), .applying(let index):
            setupAliases.indices.contains(index) ? setupAliases[index] : nil
        default:
            nil
        }
    }

    private var currentIndex: Int? {
        switch step {
        case .setup(let index), .applying(let index): index
        default: nil
        }
    }

    /// Whether SwarmBar can make the changes itself over ssh. Its one-shot
    /// channel runs the helper the way the host is watched: as the login
    /// user, or as root through `sudo -n`. Watching every user without
    /// passwordless sudo would need a password, which SwarmBar never
    /// handles, so there only the command and the paste remain. A root
    /// login is judged the same way, since its channel still goes through
    /// `sudo -n` for every user.
    func canLetSwarmBarDoIt(_ alias: String) -> Bool {
        guard let row = rows.first(where: { $0.id == alias }), row.problem == nil,
              let user = inputs[alias]?.user, let chosen = watchAs[alias]
        else { return false }
        if case .cantConnect = row.assessment?.status { return false }
        return chosen == .loginUser || user.sudoOK
    }

    func plan(for alias: String) -> SetupPlan? {
        plans[alias]
    }

    /// The changes the helper is asked to make.
    func sentChanges(for alias: String) -> [PlannedChange] {
        plans[alias]?.changes.filter(\.isSent) ?? []
    }

    /// "Edit by hand" items: changes that are never sent, each with its
    /// description, which says what to do and why SwarmBar can't.
    func handEdits(for alias: String) -> [String] {
        plans[alias]?.changes.filter { !$0.isSent }.map(\.description) ?? []
    }

    /// The narrow sudo rule is root for that account, which the view says
    /// whenever the plan sets it up.
    func everyUserWarning(for alias: String) -> String? {
        plans[alias]?.sudoersUser.map(SetupCommand.everyUserWarning(user:))
    }

    /// The setup command, or why there is none. nil before there is a plan.
    func command(for alias: String) -> Result<String, SetupCommand.Unavailable>? {
        guard let plan = plans[alias] else { return nil }
        guard let sha = services.helperSHA256 else { return .failure(.couldNotEncode) }
        return SetupCommand.command(plan: plan, system: plan.system, version: services.helperVersion,
                                    helperSHA256: sha)
    }

    func prompt(for alias: String) -> SetupCommand.Prompt? {
        guard let plan = plans[alias] else { return nil }
        let name = rows.first { $0.id == alias }?.displayName ?? alias
        return SetupCommand.prompt(plan: plan, hostName: name)
    }

    /// Changes the paste prompt leaves out, to be made another way.
    func pasteOmissions(for alias: String) -> [String] {
        guard let plan = plans[alias], let prompt = prompt(for: alias) else { return [] }
        return prompt.omitted.map { plan.changes[$0].description }
    }

    /// "Make these changes": applies the current host's plan, checks the
    /// host again, and moves on only if it is really done.
    func makeChanges() async {
        guard !isWorking, let index = currentIndex, let alias = currentAlias, let plan = plans[alias],
              canLetSwarmBarDoIt(alias)
        else { return }
        isWorking = true
        defer { isWorking = false }
        step = .applying(hostIndex: index)
        progress = [:]
        await services.apply(plan, alias: alias) { [weak self] change, outcome in
            self?.progress[change] = outcome
        }
        await recheck(alias, index: index)
    }

    /// "I've pasted it, check now", "I've run it, check now", and "Check
    /// again" after changes were made: the host is only done when a fresh
    /// look says so. Otherwise it is planned again from that look, which is
    /// how a narrow-rule host's other homes come into the plan once the
    /// rule is in place.
    func confirmPastedOrRan() async {
        guard !isWorking, let index = currentIndex, let alias = currentAlias else { return }
        isWorking = true
        defer { isWorking = false }
        await recheck(alias, index: index)
    }

    /// Moves on without changing anything. The host stays registered with
    /// its watch-as, as the user left it.
    func skipHost() {
        guard !isWorking, let index = currentIndex else { return }
        advance(from: index)
    }

    /// Waits for any check a pick started. The view never needs it; tests
    /// and callers that must see the result do.
    func waitForChecks() async {
        let running = checks
        checks = []
        for check in running { await check.value }
    }

    // MARK: Internals

    private func reset() {
        for check in checks { check.cancel() }
        checks = []
        seed { watchAs = [:] }
        rows = []
        inputs = [:]
        plans = [:]
        path = [:]
        defaultPaths = [:]
        progress = [:]
        setupAliases = []
        registered = []
        mode = .setUp
    }

    private func seed(_ body: () -> Void) {
        seeding = true
        body()
        seeding = false
    }

    /// A cantConnect row can't be ticked, nor can one whose name is unusable.
    private static func canCheck(_ row: Row) -> Bool {
        guard row.problem == nil, let assessment = row.assessment else { return false }
        if case .cantConnect = assessment.status { return false }
        return true
    }

    private func setRow(_ alias: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == alias }) else { return }
        change(&rows[index])
    }

    private func probe(_ aliases: [String], setDefaultCheck: Set<String>) async {
        guard !aliases.isEmpty else { return }
        for alias in aliases { setRow(alias) { $0.isChecking = true } }
        for await (alias, outcome) in services.probeAll(aliases) {
            record(alias, outcome, setDefaultCheck: setDefaultCheck.contains(alias))
        }
    }

    /// Stores a probe and assesses it. The suggestion fills in a host's
    /// watch-as only when it has none yet, so a pick survives a re-check.
    private func record(_ alias: String, _ outcome: HostAssessmentInput, setDefaultCheck: Bool) {
        inputs[alias] = outcome
        if watchAs[alias] == nil {
            let suggested = HostAssessment.assess(
                user: outcome.user, root: outcome.root, failure: outcome.failure, watchAs: nil
            ).suggestedWatchAs
            if let suggested { seed { watchAs[alias] = suggested } }
        }
        reassess(alias)
        setRow(alias) { row in
            row.isChecking = false
            if setDefaultCheck { row.isChecked = Self.canCheck(row) && Self.hasAgents(outcome) }
        }
    }

    private static func hasAgents(_ outcome: HostAssessmentInput) -> Bool {
        guard let user = outcome.user, !user.processesFailed else { return false }
        return user.processes.contains { ProbeResult.tool(forProcess: $0.comm) != nil }
    }

    private func reassess(_ alias: String) {
        guard let input = inputs[alias] else { return }
        let assessment = HostAssessment.assess(
            user: input.user, root: input.root, failure: input.failure, watchAs: watchAs[alias])
        setRow(alias) { row in
            row.assessment = assessment
            if !Self.canCheck(row) { row.isChecked = false }
        }
    }

    /// Same machine under two aliases (`devbox` and `devbox.ts`): one row,
    /// the one that connected.
    private func collapseRows() {
        rows = HostCandidates.collapse(
            rows, hostname: { inputs[$0.id]?.user?.hostname }, connected: { inputs[$0.id]?.user != nil })
    }

    /// The alias as given and the default display name, or the host the
    /// registry already holds under that alias with only its watch-as
    /// changed. A host with no pick yet is watched as the login user, which
    /// works without sudo; the pick in step 3 changes it.
    @discardableResult
    private func register(_ alias: String) -> Bool {
        let chosen = watchAs[alias] ?? .loginUser
        var host = registry.hosts.first { $0.alias == alias } ?? RemoteHost(alias: alias, watchAs: chosen)
        host.watchAs = chosen
        guard registry.upsert(host) else { return false }
        registered.insert(alias)
        return true
    }

    private func watchAsChanged(_ alias: String) {
        reassess(alias)
        if registered.contains(alias) { register(alias) }
        if currentAlias == alias { prepare(alias) }
        // Root's view is only probed for when it could be had: sudo works,
        // or root's helper is there for the narrow rule. Without either,
        // asking again would only say the same thing.
        guard watchAs[alias] == .everyUser, let input = inputs[alias], input.root == nil, let user = input.user,
              user.sudoOK || user.helper.contains(where: { $0.path == HelperLaunch.rootHelperPath })
        else { return }
        setRow(alias) { $0.isChecking = true }
        checks.append(Task { [weak self] in
            guard let self else { return }
            let outcome = await self.services.probe(alias)
            guard !Task.isCancelled else { return }
            self.record(alias, outcome, setDefaultCheck: false)
            if self.currentAlias == alias { self.prepare(alias) }
        })
    }

    /// Plans the host from the view it is watched with: root's for every
    /// user when there is one, the login user's otherwise, which the plan
    /// marks partial. No plan while the user still has to pick.
    private func prepare(_ alias: String) {
        plans[alias] = nil
        if rows.first(where: { $0.id == alias })?.problem != Self.unusableAlias {
            setRow(alias) { $0.problem = nil }
        }
        guard let chosen = watchAs[alias], let input = inputs[alias], let user = input.user else { return }
        let probe = chosen == .everyUser ? (input.root ?? user) : user
        do {
            plans[alias] = switch mode {
            case .setUp:
                try services.plan(probe: probe, watchAs: chosen, loginEUID: user.euid, loginUser: user.user)
            case .undo:
                try services.undoPlan(probe: probe, watchAs: chosen, loginEUID: user.euid, loginUser: user.user)
            }
        } catch SetupPlanner.PlanError.noHome(let who) {
            setRow(alias) { $0.problem = Self.noHomeMessage(user: who) }
            return
        } catch {
            setRow(alias) { $0.problem = Self.planFailed }
            return
        }
        let fallback = defaultPath(alias)
        let kept = path[alias].flatMap { $0 != defaultPaths[alias] && isAvailable($0, alias) ? $0 : nil }
        path[alias] = kept ?? fallback
        defaultPaths[alias] = fallback
    }

    private func defaultPath(_ alias: String) -> SetupPath {
        if canLetSwarmBarDoIt(alias) { return .swarmBar }
        return isAvailable(.command, alias) ? .command : .paste
    }

    private func isAvailable(_ path: SetupPath, _ alias: String) -> Bool {
        switch path {
        case .swarmBar: canLetSwarmBarDoIt(alias)
        case .command: if case .success = command(for: alias) { true } else { false }
        case .paste: true
        }
    }

    private func recheck(_ alias: String, index: Int) async {
        setRow(alias) { $0.isChecking = true }
        record(alias, await services.probe(alias), setDefaultCheck: false)
        prepare(alias)
        if isFinished(alias) { advance(from: index) }
    }

    /// Setting up is done when the assessment says Ready. Undoing is done
    /// when a fresh look leaves nothing for the helper to remove.
    private func isFinished(_ alias: String) -> Bool {
        switch mode {
        case .setUp:
            return rows.first { $0.id == alias }?.assessment?.status == .ready
        case .undo:
            guard let plan = plans[alias] else { return false }
            return !plan.changes.contains(where: \.isSent)
        }
    }

    private func advance(from index: Int) {
        progress = [:]
        let next = index + 1
        guard setupAliases.indices.contains(next) else {
            step = .done
            return
        }
        step = .setup(hostIndex: next)
        prepare(setupAliases[next])
    }
}

/// The real thing: ssh config, ProbeRunner, SetupPlanner and SetupApplier.
@MainActor
final class LiveRemoteWizardServices: RemoteWizardServices {
    enum Failure: Error {
        /// The bridge files are missing from the app bundle.
        case bridgesMissing
    }

    /// `ssh -G` runs at once, at most this many.
    static let maxResolves = 8

    private let runner: ProbeRunner?
    private let bundled: BundledBridges?
    private let sshDirectory: URL
    let helperVersion: String
    let helperSHA256: String?

    init(
        sshDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"),
        bundle: Bundle = .main
    ) {
        self.sshDirectory = sshDirectory
        runner = HelperInstaller.bundledHelper.map { ProbeRunner(helperSource: $0) }
        bundled = BundledBridges.load(from: bundle)
        helperVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        helperSHA256 = HelperInstaller.bundledDigest
    }

    func candidates() async -> [String] {
        let config = sshDirectory.appendingPathComponent("config")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        let aliases = SSHConfigParser.aliases(in: text, baseDirectory: sshDirectory) {
            try? String(contentsOf: $0, encoding: .utf8)
        }
        var resolved: [String: SSHResolved] = [:]
        await withTaskGroup(of: (String, SSHResolved?).self) { group in
            var pending = aliases[...]
            for _ in 0..<min(Self.maxResolves, pending.count) {
                let alias = pending.removeFirst()
                group.addTask { (alias, await HostCandidates.resolve(alias: alias)) }
            }
            while let (alias, result) = await group.next() {
                if let result { resolved[alias] = result }
                if let alias = pending.popFirst() {
                    group.addTask { (alias, await HostCandidates.resolve(alias: alias)) }
                }
            }
        }
        return HostCandidates.filter(aliases, resolved: resolved)
    }

    private static let helperMissing = HostProblem.other("The helper is missing from SwarmBar's app bundle")

    func probe(_ alias: String) async -> HostAssessmentInput {
        guard let runner else { return (nil, nil, Self.helperMissing) }
        return await runner.probe(alias: alias)
    }

    func probeAll(_ aliases: [String]) -> AsyncStream<(String, HostAssessmentInput)> {
        if let runner { return runner.probeAll(aliases) }
        return AsyncStream { continuation in
            for alias in aliases { continuation.yield((alias, (nil, nil, Self.helperMissing))) }
            continuation.finish()
        }
    }

    /// No Kimi build is asked which hook events it takes, so the planner
    /// writes its full list. That list is the one the local toggle writes on
    /// every Kimi and BearCode build, and every name in it is in both
    /// engines' enums.
    func plan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int, loginUser: String) throws -> SetupPlan {
        guard let bundled else { throw Failure.bridgesMissing }
        return try SetupPlanner.plan(probe: probe, watchAs: watchAs, bundled: bundled, kimiEvents: [:],
                                     loginEUID: loginEUID, loginUser: loginUser)
    }

    func undoPlan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int, loginUser: String) throws -> SetupPlan {
        try SetupPlanner.undoPlan(probe: probe, watchAs: watchAs, loginEUID: loginEUID, loginUser: loginUser)
    }

    /// A channel of its own, shut down after, so the wizard never shares a
    /// helper process with a monitor that is polling the same host. The
    /// applier installs or updates the helper itself before its first write.
    func apply(
        _ plan: SetupPlan, alias: String, progress: @escaping @MainActor (Int, SetupApplier.StepOutcome) -> Void
    ) async {
        let channel = SSHChannel(launch: .ssh(alias: alias, watchAs: plan.watchAs))
        await SetupApplier(connection: channel).apply(plan, progress: progress)
        await channel.shutdown()
    }
}
