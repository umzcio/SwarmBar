import Foundation
import Observation

/// One host's probe: the login user's view, root's view when one was taken,
/// and why the probe failed when it did. Exactly what ProbeRunner returns.
typealias HostAssessmentInput = ProbeRunner.Outcome

/// What ssh config offered the wizard. A config that is not there gives an
/// empty list with no problems; one that is there but could not be read
/// says so, because "found nothing" and "could not look" must never render
/// the same.
struct HostCandidateList: Equatable, Sendable {
    var aliases: [String] = []
    /// Aliases left out because they name a git forge or log in as `git`.
    var skippedGitHosts: [String] = []
    /// One sentence per file that is there but could not be read: the
    /// config itself, or a file it includes.
    var readProblems: [String] = []
}

/// The wizard's own failures, in words the row can show.
enum RemoteWizardError: LocalizedError, Equatable {
    case bridgesMissing

    var errorDescription: String? {
        switch self {
        case .bridgesMissing: "SwarmBar's bridge scripts are missing from the app."
        }
    }
}

/// Everything the wizard does that leaves this process: reading ssh config,
/// probing hosts, planning against the bundled bridges, and making changes
/// over ssh. A protocol so the model's tests run on fakes and never start
/// ssh.
@MainActor
protocol RemoteWizardServices: AnyObject {
    func candidates() async -> HostCandidateList
    func probe(_ alias: String) async -> HostAssessmentInput
    /// Probes several hosts at once and yields each as it finishes, so
    /// each row can stop its spinner on its own. Ending the stream early
    /// stops the probes still running.
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
///
/// One thing happens at a time. While a probe runs (`isProbing`) or changes
/// are being made (`isWorking`), every action is ignored, so a plan is never
/// built from a look that is about to be replaced.
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

    /// How the window was asked to open: at the intro, or at step 3 for one
    /// registered host from Settings.
    enum Entry: Equatable, Sendable {
        case fresh
        case setUp(alias: String)
        case undo(alias: String)
    }

    /// The pill a row shows on the pick and on done.
    enum Pill: Equatable { case ready, partial, needsSetup, cantConnect, cantContinue, undone }

    /// One tool's lines in "Let SwarmBar do it" and "Show what it will
    /// change".
    struct ChangeGroup: Equatable, Identifiable {
        var title: String
        var lines: [String]
        var id: String { title }
    }

    /// Who runs the agents on a host, from the login user's own view, for
    /// the watch-as choice.
    struct WatchContext: Equatable {
        var loginUser: String
        var sudoOK: Bool
        /// Agents other accounts run, which only watching every user shows.
        /// nil when the process list could not be read.
        var otherSessions: Int?
        var otherUsers: [String]
        /// "2 Codex, 1 Grok Build".
        var otherSummary: String
    }

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
    /// A row whose probe was stopped before it answered.
    static let notChecked = "Not checked"

    static let nothingToInstall = "Nothing to install. Answers are keystrokes in tmux."
    /// ps failed, so which sessions are in tmux is unknown, not none.
    static let tmuxUnknown = "SwarmBar couldn't list the processes on this host, so it can't tell which sessions are in tmux."
    static let sudoersPath = "/etc/sudoers.d/swarmbar"
    /// Answered with keystrokes or walked by label, so nothing is installed
    /// for them.
    static let keystrokeTools: [AgentTool] = [.codex, .grokBuild, .antigravity]
    /// Answered with keystrokes or screen reads into a tmux pane on a remote
    /// host. Claude Code and OpenCode answer over their hooks instead.
    static let toolsNeedingTmux: [AgentTool] = [.codex, .kimiCode, .bearCode, .grokBuild, .antigravity]

    /// The rule the helper writes for the narrow sudo setup, as it writes it.
    static func sudoersLine(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: \(HelperLaunch.rootHelperPath)"
    }

    static func noHomeMessage(user: String) -> String {
        "Couldn't find a home folder for \(user) on this host."
    }

    private(set) var step: Step = .intro
    private(set) var rows: [Row] = []
    private(set) var mode: Mode = .setUp
    /// Per alias. Starts from each host's suggestion, and stays empty for a
    /// host where the user has to pick. A change reassesses the host from
    /// the probe already taken, updates the registry once the host is
    /// registered, and replans it in step 3. Ignored while changes are
    /// being made, since the plan being applied was made for the old pick.
    var watchAs: [String: WatchAs] = [:] {
        didSet {
            guard !seeding else { return }
            if isWorking {
                seed { watchAs = oldValue }
                return
            }
            for alias in Set(oldValue.keys).union(watchAs.keys) where oldValue[alias] != watchAs[alias] {
                watchAsChanged(alias, byUser: true)
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
    /// For the pick screen's "Skipped: github.com, bitbucket.org (git hosts)."
    private(set) var skippedGitHosts: [String] = []
    /// ssh config files that are there but could not be read.
    private(set) var configProblems: [String] = []
    /// True while changes are being made or a host is being checked again
    /// from step 3.
    private(set) var isWorking = false
    /// True while hosts are being looked for or checked again.
    private(set) var isProbing = false
    /// The plan `progress` is reported against. Kept apart from `plans`,
    /// which the check after applying replaces, so the progress list never
    /// reads one plan's outcomes against another plan's changes.
    private(set) var appliedPlan: SetupPlan?
    /// A run of "Let SwarmBar do it" ended without the host being done, and
    /// step 3 is showing the fresh plan the check after it made. The run's
    /// outcomes stay in `appliedPlan` and `progress` until the next run.
    var unfinishedRun: Bool {
        guard appliedPlan != nil, case .setup = step else { return false }
        return true
    }
    /// Opened at step 3 from Settings, where there is no pick to go back
    /// to, so the view's Back closes the window instead.
    private(set) var openedAtSetup = false
    /// Root's view being taken in the background after a pick.
    private var rootChecks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored private let services: any RemoteWizardServices
    @ObservationIgnored private let registry: RemoteHostRegistry
    @ObservationIgnored private var inputs: [String: HostAssessmentInput] = [:]
    /// Hosts this run has put in the registry, so a later pick updates them.
    @ObservationIgnored private var registered: Set<String> = []
    /// The path last chosen for a host by default, so a replan may change
    /// a default but never a path the user picked.
    @ObservationIgnored private var defaultPaths: [String: SetupPath] = [:]
    /// The command and the prompt for each host's current plan, built once
    /// per plan rather than on every read.
    @ObservationIgnored private var artifacts: [String: Artifacts] = [:]
    /// Set while the model writes `watchAs` itself, which is not a pick.
    @ObservationIgnored private var seeding = false
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Bumped by every fresh start, so work left over from an earlier run
    /// never lands in this one.
    @ObservationIgnored private var generation = 0

    private struct Artifacts {
        var command: Result<String, SetupCommand.Unavailable>
        var prompt: SetupCommand.Prompt
    }

    init(services: any RemoteWizardServices, registry: RemoteHostRegistry) {
        self.services = services
        self.registry = registry
    }

    /// Something is in flight, so actions wait.
    var isBusy: Bool { isWorking || isProbing || !rootChecks.isEmpty }

    /// The release the setup command downloads the helper from.
    var helperVersion: String { services.helperVersion }

    // MARK: Opening

    /// What the window does when it is asked to open. A fresh open shows
    /// the intro and reaches out to nothing. Changes being made are never
    /// interrupted, so a fresh open while they run shows them instead.
    func open(_ entry: Entry) async {
        guard !isWorking else { return }
        cancel()
        switch entry {
        case .fresh:
            reset()
            step = .intro
        case .setUp(let alias):
            await startSetUp(alias: alias)
        case .undo(let alias):
            await startUndo(alias: alias)
        }
    }

    var skippedLine: String? {
        skippedGitHosts.isEmpty ? nil : "Skipped: \(skippedGitHosts.joined(separator: ", ")) (git hosts)."
    }

    // MARK: Steps 1 and 2

    /// Reads ssh config, probes every candidate, and lands on the pick.
    func lookForHosts() async {
        guard !isBusy else { return }
        reset()
        let run = generation
        step = .checking
        await probing { [self] in
            let found = await services.candidates()
            guard !Task.isCancelled else { return }
            skippedGitHosts = found.skippedGitHosts
            configProblems = found.readProblems
            rows = found.aliases.map {
                Row(id: $0, displayName: RemoteHost.defaultDisplayName(for: $0), assessment: nil,
                    isChecked: false, isChecking: true)
            }
            await probe(found.aliases, setDefaultCheck: Set(found.aliases))
        }
        // A look that was stopped and replaced by a newer one returns late,
        // and must not move the newer one on while it is still checking.
        guard generation == run else { return }
        if step == .checking { step = .pick }
        collapseRows()
    }

    /// "Add a host by name". A name ssh could read as an option is never
    /// probed.
    func addHost(alias: String) async {
        guard step == .pick, !isBusy else { return }
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !rows.contains(where: { $0.id == alias }) else { return }
        let safe = SSHConfigParser.isSafeAlias(alias)
        rows.append(Row(id: alias, displayName: RemoteHost.defaultDisplayName(for: alias), assessment: nil,
                        isChecked: false, isChecking: safe, problem: safe ? nil : Self.unusableAlias))
        guard safe else { return }
        await probing { [self] in await probe([alias], setDefaultCheck: [alias]) }
        collapseRows()
    }

    /// Probes every row again. The user's ticks stay, except that a host
    /// which could not be checked before gets the default tick now.
    func checkAgain() async {
        guard step == .pick, !isBusy else { return }
        let aliases = rows.filter { $0.problem != Self.unusableAlias }.map(\.id)
        let uncheckable = Set(rows.filter { !Self.canCheck($0) }.map(\.id))
        await probing { [self] in await probe(aliases, setDefaultCheck: uncheckable) }
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
    /// at once, then opens step 3 on the first host that needs it. A root
    /// view still being taken for a pick is dropped: the pick stands, and
    /// step 3 checks the host again before it is called done.
    func continueFromPick() async {
        guard step == .pick, !isWorking, !isProbing else { return }
        cancelRootChecks()
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
        appliedPlan = nil
        if queue.isEmpty {
            step = .done
        } else {
            step = .setup(hostIndex: 0)
            prepare(queue[0])
        }
    }

    /// Back from the pick to the intro, stopping any probe, or from step 3
    /// to the pick while nothing is being applied. Hosts already registered
    /// stay registered. Opened from Settings there is no pick to return to,
    /// so the view closes the window instead. From a finished run, back is
    /// that host's step 3, never the pick.
    func back() {
        switch step {
        case .applying(let index):
            guard !isWorking else { return }
            step = .setup(hostIndex: index)
        case .checking, .pick:
            guard !openedAtSetup, !isWorking else { return }
            stopProbing()
            step = .intro
        case .setup:
            guard !openedAtSetup, !isWorking else { return }
            cancelRootChecks()
            progress = [:]
            appliedPlan = nil
            setupAliases = []
            clearPlanningProblems()
            step = .pick
        case .intro, .done:
            break
        }
    }

    /// The window closed: stop every probe. Changes already being made run
    /// to their end, since each one is guarded on the host by its own hash.
    func cancel() {
        stopProbing()
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
        guard !isBusy else { return }
        reset()
        let run = generation
        self.mode = mode
        openedAtSetup = true
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
            await probing { [self] in
                let outcome = await services.probe(alias)
                guard !Task.isCancelled else { return }
                record(alias, outcome, setDefaultCheck: false)
            }
        }
        guard generation == run else { return }
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

    /// "Edit by hand" items, each with its description, which says what to
    /// do and why SwarmBar can't. A skipped change is not one: nothing is
    /// needed there, so it stays in its tool's group.
    func handEdits(for alias: String) -> [String] {
        plans[alias]?.changes.filter { $0.action == .byHand }.map(\.description) ?? []
    }

    /// Every change but the hand edits, grouped by tool in AgentTool order,
    /// with a line for each keystroke tool the host has, since those need
    /// nothing installed. The command also installs the helper and the sudo
    /// rule, which no PlannedChange stands for, so its list says so too.
    func changeGroups(for alias: String, forCommand: Bool = false) -> [ChangeGroup] {
        guard let plan = plans[alias] else { return [] }
        let present = presentTools(alias)
        var groups: [ChangeGroup] = []
        for tool in AgentTool.allCases {
            var lines = plan.changes.filter { $0.tool == tool && $0.action != .byHand }.map(\.description)
            if Self.keystrokeTools.contains(tool) && present.contains(tool) {
                lines.append(Self.nothingToInstall)
            }
            if !lines.isEmpty { groups.append(ChangeGroup(title: tool.label, lines: lines)) }
        }
        var shared = plan.changes.filter { $0.tool == nil && $0.action != .byHand }.map(\.description)
        if forCommand {
            if plan.installHelper { shared.append("Install SwarmBar's helper at \(plan.helperDestination)") }
            if let user = plan.sudoersUser {
                shared.append("Let \(user) run SwarmBar's helper as root, in \(Self.sudoersPath)")
            }
        }
        if !shared.isEmpty { groups.append(ChangeGroup(title: "Shared", lines: shared)) }
        return groups
    }

    /// The probe a host is judged on as it is watched, and the account
    /// whose homes and agents that means. nil before the host answers.
    private func watchedView(_ alias: String) -> (probe: ProbeResult, only: String?)? {
        guard let input = inputs[alias], let user = input.user else { return nil }
        if watchAs[alias] == .everyUser { return (input.root ?? user, nil) }
        return (user, user.user)
    }

    /// Tools with state or a running agent in the homes the host is watched
    /// for.
    private func presentTools(_ alias: String) -> Set<AgentTool> {
        guard let (probe, only) = watchedView(alias) else { return [] }
        var found = Set<AgentTool>()
        for home in probe.homes where only == nil || home.user == only {
            for name in probe.tools[home.path] ?? [] {
                if let tool = ProbeResult.tool(named: name) { found.insert(tool) }
            }
        }
        for process in probe.processes where only == nil || process.user == only {
            if let tool = ProbeResult.tool(forProcess: process.comm) { found.insert(tool) }
        }
        return found
    }

    func watchContext(for alias: String) -> WatchContext? {
        guard let user = inputs[alias]?.user else { return nil }
        guard !user.processesFailed else {
            return WatchContext(loginUser: user.user, sudoOK: user.sudoOK, otherSessions: nil,
                                otherUsers: [], otherSummary: "")
        }
        let others = user.processes.filter {
            $0.user != user.user && ProbeResult.tool(forProcess: $0.comm) != nil
        }
        var counts: [AgentTool: Int] = [:]
        for process in others {
            if let tool = ProbeResult.tool(forProcess: process.comm) { counts[tool, default: 0] += 1 }
        }
        let summary = AgentTool.allCases.compactMap { tool in counts[tool].map { "\($0) \(tool.label)" } }
        return WatchContext(
            loginUser: user.user, sudoOK: user.sudoOK, otherSessions: others.count,
            otherUsers: Set(others.map(\.user)).sorted(), otherSummary: summary.joined(separator: ", "))
    }

    /// One line per tool whose sessions here are outside tmux, where a
    /// remote keystroke can't reach them. A process list that failed says
    /// so, since "could not look" must not read as "all in tmux".
    func notInTmuxLines(for alias: String) -> [String] {
        guard let (probe, only) = watchedView(alias) else { return [] }
        if probe.processesFailed { return [Self.tmuxUnknown] }
        var counts: [AgentTool: Int] = [:]
        for process in probe.processes where process.pane == nil && (only == nil || process.user == only) {
            if let tool = ProbeResult.tool(forProcess: process.comm), Self.toolsNeedingTmux.contains(tool) {
                counts[tool, default: 0] += 1
            }
        }
        return AgentTool.allCases.compactMap { tool in
            counts[tool].map { count in
                count == 1
                    ? "1 \(tool.label) session isn't in tmux: answer it in its terminal"
                    : "\(count) \(tool.label) sessions aren't in tmux: answer them in their terminals"
            }
        }
    }

    func pill(for row: Row) -> Pill? {
        if row.isChecking || row.problem == Self.notChecked { return nil }
        if row.problem != nil { return .cantContinue }
        switch row.assessment?.status {
        case nil: return nil
        case .cantConnect: return .cantConnect
        case .needsSetup: return .needsSetup
        case .ready: return (row.assessment?.hiddenSessions ?? 0) > 0 ? .partial : .ready
        }
    }

    /// Undoing finished for this host: a fresh look left nothing to remove.
    func isUndone(_ alias: String) -> Bool {
        mode == .undo && isFinished(alias)
    }

    /// The done step's pill. An undone host needs setup again, which is the
    /// point, so it gets a neutral pill rather than a warning.
    func donePill(for row: Row) -> Pill? {
        isUndone(row.id) ? .undone : pill(for: row)
    }

    /// The hosts this run put in the registry, for the done step.
    var watchedRows: [Row] {
        rows.filter { registered.contains($0.id) }
    }

    /// The name the registry gave the host, which is the one its sessions
    /// carry, or the row's own before it is registered.
    func watchedName(_ alias: String) -> String {
        registry.hosts.first { $0.alias == alias }?.displayName
            ?? rows.first { $0.id == alias }?.displayName ?? alias
    }

    /// The narrow sudo rule is root for that account, which the view says
    /// whenever the plan sets it up.
    func everyUserWarning(for alias: String) -> String? {
        plans[alias]?.sudoersUser.map(SetupCommand.everyUserWarning(user:))
    }

    /// The setup command, or why there is none. nil before there is a plan.
    func command(for alias: String) -> Result<String, SetupCommand.Unavailable>? {
        artifacts[alias]?.command
    }

    func prompt(for alias: String) -> SetupCommand.Prompt? {
        artifacts[alias]?.prompt
    }

    /// Changes the paste prompt leaves out, to be made another way.
    func pasteOmissions(for alias: String) -> [String] {
        guard let plan = plans[alias], let prompt = artifacts[alias]?.prompt else { return [] }
        return prompt.omitted.map { plan.changes[$0].description }
    }

    /// "Make these changes": applies the current host's plan, checks the
    /// host again, and moves on only if it is really done. Never while a
    /// root view is still being taken, since the plan is about to change.
    /// A run that leaves the host not done returns to its step 3, which
    /// shows the fresh plan with all three paths: nothing is written that
    /// the screen did not list first.
    func makeChanges() async {
        guard !isBusy, let index = currentIndex, let alias = currentAlias, let plan = plans[alias],
              canLetSwarmBarDoIt(alias)
        else { return }
        isWorking = true
        defer { isWorking = false }
        step = .applying(hostIndex: index)
        progress = [:]
        appliedPlan = plan
        await services.apply(plan, alias: alias) { [weak self] change, outcome in
            self?.progress[change] = outcome
        }
        await recheck(alias, index: index)
        if step == .applying(hostIndex: index) { step = .setup(hostIndex: index) }
    }

    /// "I've pasted it, check now", "I've run it, check now", and "Check
    /// again" after changes were made: the host is only done when a fresh
    /// look says so. Otherwise it is planned again from that look, which is
    /// how a narrow-rule host's other homes come into the plan once the
    /// rule is in place.
    func confirmPastedOrRan() async {
        guard !isBusy, let index = currentIndex, let alias = currentAlias else { return }
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

    /// Waits for any root view a pick started taking. The view never needs
    /// it; tests and callers that must see the result do.
    func waitForChecks() async {
        for check in Array(rootChecks.values) { await check.value }
    }

    // MARK: Probing

    /// Runs a probe in a task the model owns, so `back` and `cancel` can
    /// stop it, and so the caller's own cancellation stops it too. Rows the
    /// probe never reached say so rather than spin.
    private func probing(_ body: @escaping @MainActor () async -> Void) async {
        isProbing = true
        let run = generation
        let task = Task { @MainActor in await body() }
        probeTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == run, probeTask == task else { return }
        probeTask = nil
        isProbing = false
        markUnprobed()
    }

    private func stopProbing() {
        probeTask?.cancel()
        probeTask = nil
        isProbing = false
        cancelRootChecks()
        markUnprobed()
    }

    private func cancelRootChecks() {
        for check in rootChecks.values { check.cancel() }
        rootChecks = [:]
        markUnprobed()
    }

    private func markUnprobed() {
        guard !isProbing, rootChecks.isEmpty else { return }
        for index in rows.indices where rows[index].isChecking {
            rows[index].isChecking = false
            // A host that answered before keeps that answer, which is the
            // last thing known about it.
            if rows[index].assessment == nil && rows[index].problem == nil {
                rows[index].problem = Self.notChecked
            }
        }
    }

    private func probe(_ aliases: [String], setDefaultCheck: Set<String>) async {
        guard !aliases.isEmpty else { return }
        for alias in aliases { setRow(alias) { $0.isChecking = true } }
        for await (alias, outcome) in services.probeAll(aliases) {
            if Task.isCancelled { break }
            record(alias, outcome, setDefaultCheck: setDefaultCheck.contains(alias))
        }
    }

    // MARK: Internals

    private func reset() {
        generation += 1
        stopProbing()
        seed { watchAs = [:] }
        rows = []
        inputs = [:]
        setPlans([:])
        path = [:]
        defaultPaths = [:]
        progress = [:]
        appliedPlan = nil
        setupAliases = []
        registered = []
        skippedGitHosts = []
        configProblems = []
        mode = .setUp
        openedAtSetup = false
    }

    /// A problem from planning belongs to step 3. Back on the pick it would
    /// leave a good host unable to be ticked, so only what the pick itself
    /// found stays: a name that can't be used, or a host never checked.
    private func clearPlanningProblems() {
        for index in rows.indices {
            guard let problem = rows[index].problem, problem != Self.unusableAlias, problem != Self.notChecked
            else { continue }
            rows[index].problem = nil
        }
    }

    private func seed(_ body: () -> Void) {
        seeding = true
        body()
        seeding = false
    }

    /// A cantConnect row can't be ticked, nor can one with a problem. The
    /// pick's check boxes are disabled by the same rule.
    static func canCheck(_ row: Row) -> Bool {
        guard row.problem == nil, let assessment = row.assessment else { return false }
        if case .cantConnect = assessment.status { return false }
        return true
    }

    private func setRow(_ alias: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == alias }) else { return }
        change(&rows[index])
    }

    /// Stores a probe and assesses it. A suggestion fills in a host's
    /// watch-as only when it has none yet, so a pick survives a re-check,
    /// and it lands exactly as a pick would, short of a second probe.
    private func record(_ alias: String, _ outcome: HostAssessmentInput, setDefaultCheck: Bool) {
        inputs[alias] = outcome
        // A fresh answer replaces whatever the last one led to. Only an
        // unusable name outlives it; step 3 plans again and says anew.
        setRow(alias) { row in
            row.isChecking = false
            if row.problem != Self.unusableAlias { row.problem = nil }
        }
        let suggested = watchAs[alias] != nil ? nil : HostAssessment.assess(
            user: outcome.user, root: outcome.root, failure: outcome.failure, watchAs: nil
        ).suggestedWatchAs
        if let suggested {
            seed { watchAs[alias] = suggested }
            watchAsChanged(alias, byUser: false)
        } else {
            reassess(alias)
            if needsReplan(alias) { prepare(alias) }
        }
        if setDefaultCheck {
            setRow(alias) { row in row.isChecked = Self.canCheck(row) && Self.hasAgents(outcome) }
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

    /// A host in step 3 is replanned whenever what it is judged on changes,
    /// except while its plan is being applied: that run reports against the
    /// plan it started with, and replans when it is done.
    private func needsReplan(_ alias: String) -> Bool {
        guard currentIndex != nil, setupAliases.contains(alias) else { return false }
        return !(isWorking && currentAlias == alias)
    }

    /// Same machine under two aliases (`devbox` and `devbox.ts`): one row,
    /// the one that connected. Only on the pick, so the host step 3 is on
    /// can never lose its row.
    private func collapseRows() {
        guard step == .checking || step == .pick else { return }
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

    private func watchAsChanged(_ alias: String, byUser: Bool) {
        reassess(alias)
        if registered.contains(alias) { register(alias) }
        if needsReplan(alias) { prepare(alias) }
        // Root's view is only probed for when the user picks every user
        // and it could be had: sudo works, or root's helper is there for
        // the narrow rule. Without either, asking again would only say the
        // same thing, and a suggestion never probes twice.
        guard byUser, watchAs[alias] == .everyUser, let input = inputs[alias], input.root == nil,
              let user = input.user,
              user.sudoOK || user.helper.contains(where: { $0.path == HelperLaunch.rootHelperPath }),
              rows.first(where: { $0.id == alias })?.isChecking == false
        else { return }
        setRow(alias) { $0.isChecking = true }
        let id = UUID()
        let run = generation
        rootChecks[id] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.services.probe(alias)
            guard !Task.isCancelled, self.generation == run, self.rootChecks[id] != nil else { return }
            self.rootChecks[id] = nil
            self.record(alias, outcome, setDefaultCheck: false)
        }
    }

    /// Plans the host from the view it is watched with: root's for every
    /// user when there is one, the login user's otherwise, which the plan
    /// marks partial. No plan while the user still has to pick.
    private func prepare(_ alias: String) {
        setPlan(nil, for: alias)
        if rows.first(where: { $0.id == alias })?.problem != Self.unusableAlias {
            setRow(alias) { $0.problem = nil }
        }
        guard let chosen = watchAs[alias], let input = inputs[alias], let user = input.user else { return }
        let probe = chosen == .everyUser ? (input.root ?? user) : user
        do {
            let plan: SetupPlan = switch mode {
            case .setUp:
                try services.plan(probe: probe, watchAs: chosen, loginEUID: user.euid, loginUser: user.user)
            case .undo:
                try services.undoPlan(probe: probe, watchAs: chosen, loginEUID: user.euid, loginUser: user.user)
            }
            setPlan(plan, for: alias)
        } catch SetupPlanner.PlanError.noHome(let who) {
            setRow(alias) { $0.problem = Self.noHomeMessage(user: who) }
            return
        } catch {
            setRow(alias) { $0.problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            return
        }
        let fallback = defaultPath(alias)
        let kept = path[alias].flatMap { $0 != defaultPaths[alias] && isAvailable($0, alias) ? $0 : nil }
        path[alias] = kept ?? fallback
        defaultPaths[alias] = fallback
    }

    private func setPlan(_ plan: SetupPlan?, for alias: String) {
        plans[alias] = plan
        artifacts[alias] = plan.map { plan in
            let command: Result<String, SetupCommand.Unavailable> = services.helperSHA256.map {
                SetupCommand.command(plan: plan, system: plan.system, version: services.helperVersion,
                                     helperSHA256: $0)
            } ?? .failure(.helperMissing)
            let name = rows.first { $0.id == alias }?.displayName ?? alias
            return Artifacts(command: command, prompt: SetupCommand.prompt(plan: plan, hostName: name))
        }
    }

    private func setPlans(_ all: [String: SetupPlan]) {
        plans = [:]
        artifacts = [:]
        for (alias, plan) in all { setPlan(plan, for: alias) }
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
        appliedPlan = nil
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
    /// `ssh -G` runs at once, at most this many.
    static let maxResolves = 8
    static let helperMissing = HostProblem.other(SetupCommand.Unavailable.helperMissing.reason)

    private let runner: ProbeRunner?
    private let bundled: BundledBridges?
    private let sshDirectory: URL
    private let home: URL
    let helperVersion: String
    let helperSHA256: String?

    /// The helper, its digest and the bridges all come from `bundle`, so
    /// the command never vouches for a helper other than the one probed.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, bundle: Bundle = .main) {
        self.home = home
        sshDirectory = home.appendingPathComponent(".ssh")
        let helper = bundle.url(forResource: "swarmbar-helper", withExtension: "py")
            .flatMap { try? Data(contentsOf: $0) }
        runner = helper.map { ProbeRunner(helperSource: $0) }
        helperSHA256 = helper.map(HelperInstaller.sha256)
        bundled = BundledBridges.load(from: bundle)
        helperVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func candidates() async -> HostCandidateList {
        await Self.readCandidates(sshDirectory: sshDirectory, home: home) {
            await HostCandidates.resolve(alias: $0)
        }
    }

    /// Reads the config and the files it includes, resolves every alias
    /// with `resolve` (at most `maxResolves` at once), and drops git hosts
    /// and duplicates. A file that is not there is ssh's own business and
    /// says nothing; one that is there and can't be read is reported.
    static func readCandidates(
        sshDirectory: URL, home: URL, resolve: @escaping @Sendable (String) async -> SSHResolved?
    ) async -> HostCandidateList {
        var list = HostCandidateList()
        let config = sshDirectory.appendingPathComponent("config")
        let text: String
        switch read(config) {
        case .missing: return list
        case .failed(let reason):
            list.readProblems.append(problem(config, home: home, reason))
            return list
        case .text(let contents): text = contents
        }
        var problems: [String] = []
        let aliases = SSHConfigParser.aliases(in: text, baseDirectory: sshDirectory, home: home) { url in
            switch read(url) {
            case .text(let contents): return contents
            case .missing: return nil
            case .failed(let reason):
                problems.append(problem(url, home: home, reason))
                return nil
            }
        }
        list.readProblems = problems

        var resolved: [String: SSHResolved] = [:]
        await withTaskGroup(of: (String, SSHResolved?).self) { group in
            var pending = aliases[...]
            for _ in 0..<min(maxResolves, pending.count) {
                let alias = pending.removeFirst()
                group.addTask { (alias, await resolve(alias)) }
            }
            while let (alias, result) = await group.next() {
                if let result { resolved[alias] = result }
                if let alias = pending.popFirst() {
                    group.addTask { (alias, await resolve(alias)) }
                }
            }
        }
        list.aliases = HostCandidates.filter(aliases, resolved: resolved)
        list.skippedGitHosts = aliases.filter { resolved[$0].map(HostCandidates.isGitHost) ?? false }
        return list
    }

    private enum Read {
        case text(String)
        case missing
        case failed(String)
    }

    private static func read(_ url: URL) -> Read {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let ns = error as NSError
            let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
                $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
            }
            if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
                || posix == ENOENT || posix == ENOTDIR {
                return .missing
            }
            return .failed(posix.map { String(cString: strerror($0)) } ?? ns.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else { return .failed("it isn't UTF-8 text") }
        return .text(text)
    }

    private static func problem(_ url: URL, home: URL, _ reason: String) -> String {
        let path = url.path
        let shown = path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
        return "Couldn't read \(shown): \(reason)"
    }

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
        guard let bundled else { throw RemoteWizardError.bridgesMissing }
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
