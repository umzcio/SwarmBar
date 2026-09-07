import Foundation
import Testing
@testable import SwarmBar

@Suite("Remote host persistence")
struct RemoteHostTests {
    private func scratchDefaults(_ name: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "swarmbar.tests.\(name)"))
        defaults.removePersistentDomain(forName: "swarmbar.tests.\(name)")
        return defaults
    }

    @Test("hosts round-trip through defaults")
    func roundTrips() throws {
        let defaults = try scratchDefaults(#function)
        let hosts = [
            RemoteHost(alias: "umzcaio.ts", displayName: "umzcaio"),
            RemoteHost(alias: "umzflash.ts", displayName: "umzflash", isEnabled: false),
        ]
        RemoteHostStore.save(hosts, to: defaults)
        #expect(RemoteHostStore.load(from: defaults) == hosts)
    }

    @Test("an empty store loads as no hosts rather than failing")
    func emptyLoads() throws {
        let defaults = try scratchDefaults(#function)
        #expect(RemoteHostStore.load(from: defaults).isEmpty)
    }

    @Test("corrupt stored data loads as no hosts rather than crashing")
    func corruptLoads() throws {
        let defaults = try scratchDefaults(#function)
        defaults.set(Data("not json".utf8), forKey: RemoteHostStore.defaultsKey)
        #expect(RemoteHostStore.load(from: defaults).isEmpty)
    }

    @Test("display name defaults to the alias with its .ts suffix removed")
    func displayNameDefault() {
        #expect(RemoteHost(alias: "umzcaio.ts").displayName == "umzcaio")
        #expect(RemoteHost(alias: "umzcaio").displayName == "umzcaio")
    }
}
