import Foundation
import Observation

/// The observable list of configured remote hosts. Views and the monitor
/// supervisor read it; every change is written through RemoteHostStore so the
/// persisted JSON stays the single source of truth.
@MainActor @Observable
final class RemoteHostRegistry {
    private(set) var hosts: [RemoteHost]
    /// Called after every persisted change so a supervisor can reconcile.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.hosts = RemoteHostStore.load(from: defaults)
    }

    func host(id: UUID) -> RemoteHost? {
        hosts.first { $0.id == id }
    }

    /// Adds or replaces a host by id. Display names are how hosts are told
    /// apart in the UI, so a name another host already holds gets " 2", " 3"...
    /// Returns false, changing nothing, when the alias could be read as an ssh
    /// option (leading dash) or is empty or has whitespace: every ssh argv in
    /// the app takes `host.alias`, so one bad entry would be an injection point.
    @discardableResult
    func upsert(_ host: RemoteHost) -> Bool {
        guard SSHConfigParser.isSafeAlias(host.alias) else { return false }
        var host = host
        let taken = Set(hosts.filter { $0.id != host.id }.map(\.displayName))
        if taken.contains(host.displayName) {
            let base = host.displayName
            var n = 2
            while taken.contains("\(base) \(n)") { n += 1 }
            host.displayName = "\(base) \(n)"
        }
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        commit()
        return true
    }

    func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
        commit()
    }

    private func commit() {
        RemoteHostStore.save(hosts, to: defaults)
        onChange?()
    }
}
