import Foundation

/// Starts, stops and restarts one monitor per configured remote host as the
/// registry changes, so adding or removing a host takes effect without a
/// relaunch. A removed or renamed host's rows are cleared here because its
/// monitor is cancelled and will never sync again to delete them itself.
@MainActor
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

    let store: SessionStore
    let registry: RemoteHostRegistry
    private let factory: Factory
    /// Where relayed hook events go. Nil in tests that only watch the
    /// supervisor's bookkeeping, which then start no relay.
    let hookServer: HookServer?
    /// What a host's helper commands go through when answering. The
    /// connection's own channel, or a recorder in tests.
    var requester: @MainActor (RemoteHostConnection) -> any RemoteRequesting = { $0.channel }
    /// The Grok and Antigravity keystroke switches, which apply to remote
    /// sessions exactly as to local ones. Injectable so tests never read
    /// the real defaults.
    var keystrokeToggles: @MainActor () -> (grok: Bool, antigravity: Bool) = {
        (SessionStore.grokKeystrokesEnabled, SessionStore.antigravityKeystrokesEnabled)
    }
    /// Sessions with an answer in flight. See `performAnswer`.
    var answering: Set<UUID> = []
    private var running: [UUID: Running] = [:]
    /// A stopped monitor until it has actually finished, and its mirror is
    /// deleted where that was asked for. Cancel is only a request: a poll in
    /// flight can still be writing the mirror, so a monitor started again
    /// for the same host waits on this rather than sharing the directory
    /// with its predecessor, and a deletion never races a write.
    private var stopping: [UUID: Task<Void, Never>] = [:]

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
