import Foundation

/// A configured remote host. Addressed by its ssh config alias, never by
/// tailnet IP, so ssh config and MagicDNS stay the single source of truth.
/// No credentials are stored here; ssh keys are.
struct RemoteHost: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var alias: String
    var displayName: String
    var isEnabled: Bool

    init(id: UUID = UUID(), alias: String, displayName: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.alias = alias
        self.displayName = displayName ?? Self.defaultDisplayName(for: alias)
        self.isEnabled = isEnabled
    }

    static func defaultDisplayName(for alias: String) -> String {
        alias.hasSuffix(".ts") ? String(alias.dropLast(3)) : alias
    }
}

enum RemoteHostStore {
    static let defaultsKey = "remoteHosts"

    static func load(from defaults: UserDefaults) -> [RemoteHost] {
        guard let data = defaults.data(forKey: defaultsKey),
              let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data)
        else { return [] }
        return hosts
    }

    static func save(_ hosts: [RemoteHost], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
