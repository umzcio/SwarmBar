import Foundation
import Testing
@testable import SwarmBar

@Suite("Remote host registry")
@MainActor
struct RemoteHostRegistryTests {
    private let defaults = UserDefaults(suiteName: "test-\(UUID())")!

    @Test func legacyEntryDecodesAsEveryUser() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","alias":"devbox.ts","displayName":"devbox","isEnabled":true}]"#
        defaults.set(Data(json.utf8), forKey: RemoteHostStore.defaultsKey)
        let registry = RemoteHostRegistry(defaults: defaults)
        #expect(registry.hosts.first?.watchAs == .everyUser)
        #expect(registry.hosts.first?.approvalsOff == [])
    }

    @Test func upsertPersistsAndNotifies() {
        let registry = RemoteHostRegistry(defaults: defaults)
        var fired = 0
        registry.onChange = { fired += 1 }
        let host = RemoteHost(alias: "devbox.ts", watchAs: .loginUser)
        registry.upsert(host)
        #expect(fired == 1)
        let reloaded = RemoteHostRegistry(defaults: defaults)
        #expect(reloaded.hosts == [host])
        #expect(reloaded.host(id: host.id) == host)
    }

    @Test func removeForgetsHost() {
        let registry = RemoteHostRegistry(defaults: defaults)
        let host = RemoteHost(alias: "devbox.ts")
        registry.upsert(host)
        registry.remove(id: host.id)
        #expect(RemoteHostRegistry(defaults: defaults).host(id: host.id) == nil)
    }

    @Test func duplicateDisplayNameGetsSuffix() {
        let registry = RemoteHostRegistry(defaults: defaults)
        registry.upsert(RemoteHost(alias: "devbox.ts"))
        let second = RemoteHost(alias: "devbox-b.ts", displayName: "devbox")
        registry.upsert(second)
        #expect(registry.host(id: second.id)?.displayName == "devbox 2")
        let third = RemoteHost(alias: "devbox-c.ts", displayName: "devbox")
        registry.upsert(third)
        #expect(registry.host(id: third.id)?.displayName == "devbox 3")
    }

    @Test func approvalsOffRoundTrips() throws {
        let host = RemoteHost(alias: "devbox.ts", approvalsOff: [.claudeCode])
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(RemoteHost.self, from: data).approvalsOff == [.claudeCode])
    }
}
