import Foundation

/// Which account's agents a remote host is watched as. Phase 1a hosts all ran
/// as root, so a stored entry that predates this choice means `.everyUser`.
enum WatchAs: String, Codable, Sendable {
    case everyUser, loginUser
}

/// A configured remote host. Addressed by its ssh config alias, never by
/// tailnet IP, so ssh config and MagicDNS stay the single source of truth.
/// No credentials are stored here; ssh keys are.
struct RemoteHost: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var alias: String
    var displayName: String
    var isEnabled: Bool
    var watchAs: WatchAs
    /// Tools whose Approve and Deny buttons are withheld for this host.
    var approvalsOff: Set<AgentTool>

    init(id: UUID = UUID(), alias: String, displayName: String? = nil, isEnabled: Bool = true,
         watchAs: WatchAs = .everyUser, approvalsOff: Set<AgentTool> = []) {
        self.id = id
        self.alias = alias
        self.displayName = displayName ?? Self.defaultDisplayName(for: alias)
        self.isEnabled = isEnabled
        self.watchAs = watchAs
        self.approvalsOff = approvalsOff
    }

    /// Entries stored before the watch-as choice existed lack both new keys, so
    /// they must decode rather than make the whole host list load as empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        alias = try c.decode(String.self, forKey: .alias)
        displayName = try c.decode(String.self, forKey: .displayName)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        watchAs = try c.decodeIfPresent(WatchAs.self, forKey: .watchAs) ?? .everyUser
        approvalsOff = try c.decodeIfPresent(Set<AgentTool>.self, forKey: .approvalsOff) ?? []
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
        // A legacy or hand-edited blob can hold an alias that ssh would read
        // as an option. Drop it here so no argv builder ever sees it; the
        // log names the count only, since the alias is the hostile part.
        let safe = hosts.filter { SSHConfigParser.isSafeAlias($0.alias) }
        if safe.count != hosts.count {
            NSLog("SwarmBar: dropped \(hosts.count - safe.count) remote host(s) with an unusable alias")
        }
        return safe
    }

    static func save(_ hosts: [RemoteHost], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
