import Foundation
import Observation

/// Starts, stops and restarts one monitor per configured remote host as the
/// registry changes, so adding or removing a host takes effect without a
/// relaunch. A removed or renamed host's rows are cleared here because its
/// monitor is cancelled and will never sync again to delete them itself.
///
/// Observable for Settings › Hosts, which shows the result of checking a
/// host again. Only `checks` and `checking` are watched.
@MainActor @Observable
final class RemoteMonitorSupervisor {
    /// Builds a host's monitor and, for a real host, the connection it polls
    /// through. Tests that only watch the supervisor's bookkeeping return a
    /// nil connection.
    typealias Factory = @MainActor (RemoteHost) -> (monitor: any SessionMonitor, connection: RemoteHostConnection?)

    private struct Running {
        let host: RemoteHost
        let task: Task<Void, Never>
        let connection: RemoteHostConnection?
        /// The host's hook relay, which runs and stops with its monitor.
        let relay: Task<Void, Never>?
    }

    /// What checking a host again from Settings found: the wizard's own
    /// assessment, plus what the row needs to say it in words.
    struct HostCheck: Equatable, Sendable {
        var assessment: HostAssessment
        /// The pick it was judged for. A different pick makes it stale.
        var watchAs: WatchAs
        /// Who the probe logged in as, for "Just dev". nil when it never
        /// connected.
        var loginUser: String?
        /// The accounts running the agents a login-user host cannot show.
        /// Empty when there are none or the process list was unreadable.
        var hiddenUsers: [String]
        /// Tools with state or a running agent in the view being watched.
        var tools: Set<AgentTool>
    }

    @ObservationIgnored let store: SessionStore
    @ObservationIgnored let registry: RemoteHostRegistry
    @ObservationIgnored private let factory: Factory
    /// Where relayed hook events go. Nil in tests that only watch the
    /// supervisor's bookkeeping, which then start no relay.
    @ObservationIgnored let hookServer: HookServer?
    /// What a host's helper commands go through when answering. The
    /// connection's own channel, or a recorder in tests.
    @ObservationIgnored var requester: @MainActor (RemoteHostConnection) -> any RemoteRequesting = { $0.channel }
    /// The Grok and Antigravity keystroke switches, which apply to remote
    /// sessions exactly as to local ones. Injectable so tests never read
    /// the real defaults.
    @ObservationIgnored var keystrokeToggles: @MainActor () -> (grok: Bool, antigravity: Bool) = {
        (SessionStore.grokKeystrokesEnabled, SessionStore.antigravityKeystrokesEnabled)
    }
    /// Sessions with an answer in flight. See `performAnswer`.
    @ObservationIgnored var answering: Set<UUID> = []
    @ObservationIgnored private var running: [UUID: Running] = [:]
    /// A stopped monitor until it has actually finished, and its mirror is
    /// deleted where that was asked for. Cancel is only a request: a poll in
    /// flight can still be writing the mirror, so a monitor started again
    /// for the same host waits on this rather than sharing the directory
    /// with its predecessor, and a deletion never races a write.
    @ObservationIgnored private var stopping: [UUID: Task<Void, Never>] = [:]

    /// The last check of each host, made only when the user asks. A host
    /// missing here is "Not checked yet", never assumed Ready.
    private(set) var checks: [UUID: HostCheck] = [:]
    /// Hosts being checked right now.
    private(set) var checking: Set<UUID> = []
    /// Probes a host by alias. Injectable so tests never start ssh.
    @ObservationIgnored var prober: @MainActor (String) async -> ProbeRunner.Outcome = { alias in
        guard let runner = RemoteMonitorSupervisor.bundledProbeRunner else {
            return (nil, nil, LiveRemoteWizardServices.helperMissing)
        }
        return await runner.probe(alias: alias)
    }

    /// Built on the first check, so a user who never asks for one never
    /// reads the bundled helper for it.
    private static let bundledProbeRunner: ProbeRunner? =
        HelperInstaller.bundledHelper.map { ProbeRunner(helperSource: $0) }

    /// Each check's assessment, by host id.
    var assessments: [UUID: HostAssessment] { checks.mapValues(\.assessment) }

    init(
        store: SessionStore, registry: RemoteHostRegistry,
        factory: @escaping Factory = defaultFactory, hookServer: HookServer? = nil
    ) {
        self.store = store
        self.registry = registry
        self.factory = factory
        self.hookServer = hookServer
    }

    /// One ssh helper per host, and a mirror in Caches keyed by the host's
    /// id, which outlives renames and alias changes.
    static let defaultFactory: Factory = { host in
        let connection = RemoteHostConnection(
            host: host,
            channel: SSHChannel(launch: .ssh(alias: host.alias, watchAs: host.watchAs)),
            mirror: RemoteMirror(root: RemoteMirror.root(forHost: host.id)))
        return (RemoteHostMonitor(connection: connection), connection)
    }

    var runningHostIDs: Set<UUID> { Set(running.keys) }

    /// The connection a running host polls through, for answering and
    /// relaying over the same helper.
    func connection(forHostID id: UUID) -> RemoteHostConnection? {
        running[id]?.connection
    }

    /// Rows carry their host's display name, which is unique among hosts.
    func connection(forHostName name: String) -> RemoteHostConnection? {
        running.values.first { $0.host.displayName == name }?.connection
    }

    func reconcile() {
        let wanted = Dictionary(uniqueKeysWithValues: registry.hosts.map { ($0.id, $0) })

        for (id, entry) in running {
            let current = wanted[id]
            if let current, current.isEnabled {
                // Approval toggles are read live, so only a change to what
                // the monitor connects to or how it labels rows restarts it.
                let changed = current.alias != entry.host.alias
                    || current.watchAs != entry.host.watchAs
                    || current.displayName != entry.host.displayName
                guard changed else { continue }
                // The mirror is kept: the new monitor's first snapshot comes
                // from a new helper stream, which resets it anyway.
                stop(id, deletingMirror: false)
            } else {
                // Disabled or removed, the stopped monitor's rows can no
                // longer be trusted, and clearing now also keeps a later
                // removal from finding nothing left to clear. The mirror
                // goes too: it can hold other users' transcripts, and
                // nothing will read it again before a fresh stream would
                // reset it.
                stop(id, deletingMirror: true)
            }
        }
        // A check is about one host as it was picked. Gone, or picked the
        // other way since, it no longer says anything true.
        let staleChecks = checks.filter { id, check in wanted[id]?.watchAs != check.watchAs }
        for id in staleChecks.keys { checks.removeValue(forKey: id) }
        // Hosts gone from the registry never start again, so nothing will
        // wait on their stopping tasks. Dropping the reference does not
        // cancel the task; the deletion still runs.
        stopping = stopping.filter { wanted[$0.key] != nil }

        for host in registry.hosts where host.isEnabled && running[host.id] == nil {
            let (monitor, connection) = factory(host)
            let store = store
            let previous = stopping.removeValue(forKey: host.id)
            let task = Task {
                await previous?.value
                await monitor.start(into: store)
            }
            var relay: Task<Void, Never>?
            if let connection, let hookServer {
                let id = host.id, fallback = host.approvalsOff
                let relayer = RemoteHookRelay(
                    connection: connection, hookServer: hookServer,
                    approvalsOff: { [weak registry = self.registry] in
                        registry?.host(id: id)?.approvalsOff ?? fallback
                    },
                    onHelperExited: { [weak store] in store?.noteRemotePanesChanged() })
                relay = Task { await relayer.run() }
            }
            running[host.id] = Running(host: host, task: task, connection: connection, relay: relay)
        }
    }

    // MARK: Checking again

    /// Probes one host the way the wizard does and publishes what it found.
    /// Runs only when the user asks, never on a timer or when Settings
    /// opens: the wizard's rule is that nothing reaches a host unasked.
    func checkAgain(hostID id: UUID) async {
        guard let host = registry.host(id: id), !checking.contains(id) else { return }
        checking.insert(id)
        defer { checking.remove(id) }
        let outcome = await prober(host.alias)
        // Removed, or pointed somewhere else, while the probe ran.
        guard let current = registry.host(id: id), current.alias == host.alias else { return }
        checks[id] = Self.check(outcome, watchAs: current.watchAs)
    }

    /// Every host, at most as many at once as the wizard probes.
    func checkAllAgain() async {
        let ids = registry.hosts.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            var pending = ids[...]
            for _ in 0..<min(ProbeRunner.maxConcurrent, pending.count) {
                let id = pending.removeFirst()
                group.addTask { await self.checkAgain(hostID: id) }
            }
            while await group.next() != nil {
                if let id = pending.popFirst() {
                    group.addTask { await self.checkAgain(hostID: id) }
                }
            }
        }
    }

    /// Drops a host's check, for when the wizard is about to change the
    /// host and the old verdict would outlive what it describes.
    func forgetCheck(hostID id: UUID) {
        if checks[id] != nil { checks.removeValue(forKey: id) }
    }

    /// Pure: the assessment for this pick, and what the row says about it.
    static func check(_ outcome: ProbeRunner.Outcome, watchAs: WatchAs) -> HostCheck {
        let assessment = HostAssessment.assess(
            user: outcome.user, root: outcome.root, failure: outcome.failure, watchAs: watchAs)
        guard let user = outcome.user else {
            return HostCheck(assessment: assessment, watchAs: watchAs, loginUser: nil, hiddenUsers: [], tools: [])
        }
        let agents = user.processesFailed ? [] : user.processes.filter {
            ProbeResult.tool(forProcess: $0.comm) != nil
        }
        let hidden = watchAs == .loginUser
            ? Set(agents.filter { $0.user != user.user }.map(\.user)).sorted() : []
        // Watching every user, root's view is the one that counts when there
        // is one. Watching the login user, only that user's agents show.
        let view = watchAs == .everyUser ? (outcome.root ?? user) : user
        var tools = Set(view.tools.values.joined().compactMap(ProbeResult.tool(named:)))
        if !view.processesFailed {
            for process in view.processes where watchAs == .everyUser || process.user == user.user {
                if let tool = ProbeResult.tool(forProcess: process.comm) { tools.insert(tool) }
            }
        }
        return HostCheck(assessment: assessment, watchAs: watchAs, loginUser: user.user,
                         hiddenUsers: hidden, tools: tools)
    }

    private func stop(_ id: UUID, deletingMirror: Bool) {
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.task.cancel()
        entry.relay?.cancel()
        // Before clearHost, so no hold outlives the rows it was for.
        hookServer?.dropRemote(hostID: id)
        store.clearHost(entry.host.displayName)
        let mirrorRoot = deletingMirror ? entry.connection?.mirror.root : nil
        let previous = stopping[id]
        stopping[id] = Task {
            await previous?.value
            await entry.task.value
            guard let mirrorRoot else { return }
            // Off the main actor: a mirror can hold thousands of files.
            await Task.detached { try? FileManager.default.removeItem(at: mirrorRoot) }.value
        }
    }
}
