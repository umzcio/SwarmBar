import Foundation
import Testing
@testable import SwarmBar

@Suite("SSH channel")
struct SSHChannelTests {
    @Test("the install command pushes over the same channel, never scp")
    func installCommandUsesStdin() {
        let argv = SSHChannel.installCommand(helperPath: "/usr/local/lib/swarmbar-helper")
        let joined = argv.joined(separator: " ")
        #expect(joined.contains("/dev/stdin"))
        #expect(joined.contains("/usr/local/lib/swarmbar-helper"))
        #expect(joined.contains("sudo -n"))
        #expect(!joined.contains("scp"))
    }

    @Test("a response line is split off the buffer, leaving the remainder")
    func framesOneLine() {
        var buffer = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        let first = SSHChannel.takeLine(from: &buffer)
        #expect(first == Data("{\"a\":1}".utf8))
        let second = SSHChannel.takeLine(from: &buffer)
        #expect(second == Data("{\"b\":2}".utf8))
        #expect(SSHChannel.takeLine(from: &buffer) == nil)
    }

    @Test("a partial line is held until its newline arrives")
    func holdsPartialLine() {
        var buffer = Data("{\"a\":".utf8)
        #expect(SSHChannel.takeLine(from: &buffer) == nil)
        buffer.append(Data("1}\n".utf8))
        #expect(SSHChannel.takeLine(from: &buffer) == Data("{\"a\":1}".utf8))
    }

    @Test("backoff grows and is capped")
    func backoffIsCapped() {
        #expect(SSHChannel.backoffSeconds(afterFailures: 0) == 1)
        #expect(SSHChannel.backoffSeconds(afterFailures: 3) == 8)
        // The boundary where the formula transitions from an uncapped 64
        // to the capped 60, so a future change to either the cap or the
        // shift is caught.
        #expect(SSHChannel.backoffSeconds(afterFailures: 6) == 60)
        #expect(SSHChannel.backoffSeconds(afterFailures: 99) == 60)
        // Negative input must not fall through Swift's smart-shift
        // semantics (1 << -1 == 0) and silently violate "at least 1 second".
        #expect(SSHChannel.backoffSeconds(afterFailures: -5) == 1)
    }

    @Test("a concurrent snapshot call is rejected while one is in flight, and the guard releases the channel afterward")
    func rejectsConcurrentSnapshotAndRecovers() async throws {
        // A hostname under .local that nothing answers for forces a real
        // mDNS lookup, which blocks for several seconds on a negative
        // answer rather than failing immediately (measured locally at
        // ~5s). That keeps the first call reliably parked inside its
        // blocking read, with no real network dependency and no elevated
        // privileges, so the busy assertion below does not have to race a
        // fast failure. The alias is unique per run so no earlier attempt
        // can leave a cached negative answer that speeds this one up.
        let alias = "swarmbar-test-\(UUID().uuidString).local"
        let channel = SSHChannel(alias: alias, helperPath: "/usr/local/lib/swarmbar-helper")

        async let first: Void = { _ = try? await channel.snapshot() }()

        // Give the first call time to pass the guard and reach its
        // blocking read; the mDNS lookup keeps it parked there for
        // seconds, so this margin only has to outlast process spawn, not
        // race a fast failure.
        try? await Task.sleep(for: .milliseconds(500))

        await #expect(throws: SSHChannelError.busy) {
            try await channel.snapshot()
        }

        // Force the parked first call to unblock instead of waiting out
        // the mDNS timeout. This drives it through its own failure path,
        // which is what should clear the in-flight flag.
        await channel.shutdown()
        await first

        // A guard that wedges the channel on the first error would be
        // worse than the reentrancy bug it fixes. .busy is thrown
        // synchronously, before any await, so if a fresh call is still
        // running well after that instant, it was not rejected as busy:
        // the guard released and it is attempting a real connection.
        let recovery = Task<SSHChannelError?, Never> {
            do {
                _ = try await channel.snapshot()
                return nil
            } catch let error as SSHChannelError {
                return error
            } catch {
                return nil
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        await channel.shutdown()
        let recoveryError = await recovery.value
        #expect(recoveryError != .busy)
    }
}
