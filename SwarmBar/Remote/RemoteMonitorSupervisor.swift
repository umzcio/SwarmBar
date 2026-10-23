import Foundation

/// Starts, stops and restarts one monitor per configured remote host as the
/// registry changes, so adding or removing a host takes effect without a
/// relaunch. A removed or renamed host's rows are cleared here because its
/// monitor is cancelled and will never sync again to delete them itself.
@MainActor
final class RemoteMonitorSupervisor {
    typealias Factory = @MainActor (RemoteHost) -> any SessionMonitor

    private let store: SessionStore
    private let registry: RemoteHostRegistry
    private let factory: Factory
    private var running: [UUID: (host: RemoteHost, task: Task<Void, Never>)] = [:]

    init(store: SessionStore, registry: RemoteHostRegistry, factory: @escaping Factory) {
        self.store = store
        self.registry = registry
        self.factory = factory
    }

    var runningHostIDs: Set<UUID> { Set(running.keys) }

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
                entry.task.cancel()
                running.removeValue(forKey: id)
                store.clearHost(entry.host.displayName)
            } else {
                entry.task.cancel()
                running.removeValue(forKey: id)
                // Disabled or removed, the stopped monitor's rows can no
                // longer be trusted, and clearing now also keeps a later
                // removal from finding nothing left to clear.
                store.clearHost(entry.host.displayName)
            }
        }

        for host in registry.hosts where host.isEnabled && running[host.id] == nil {
            let monitor = factory(host)
            let store = store
            let task = Task { await monitor.start(into: store) }
            running[host.id] = (host, task)
        }
    }
}
