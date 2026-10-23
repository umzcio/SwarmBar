import CryptoKit
import Foundation

/// Keeps the helper a host runs identical to the one this build bundles.
/// The monitor runs it on every poll, and the setup wizard runs it before
/// its first request, since the wizard can reach a host before any monitor
/// has installed anything there.
enum HelperInstaller {
    /// What a host watched as every user says when sudo will no longer
    /// install the helper without a password. Polling carries on with the
    /// old helper meanwhile, if it still answers.
    static let updateNeedsSetupMessage =
        "SwarmBar was updated. Run the setup command again to update its helper."

    /// An install that did not take. `message` is short enough for a row;
    /// `stderr` is everything the remote said, because the line that
    /// matters is not always the first one (ssh prints host key warnings
    /// ahead of whatever sudo says).
    struct InstallFailure: Error, Sendable, Equatable {
        let message: String
        let stderr: String
    }

    /// Pushes the helper's bytes to a host and returns once they are in
    /// place, or throws `InstallFailure`. Injectable so tests never run
    /// ssh.
    typealias Runner = @Sendable (_ helper: Data, _ alias: String, _ watchAs: WatchAs) async throws -> Void

    /// What the helper on a channel said when asked who it is.
    enum Check: Sendable, Equatable {
        /// It is the bundled helper, byte for byte.
        case current
        /// It answers, but it is some other version.
        case stale
        /// It did not answer properly, which a missing helper and a host
        /// that is down look exactly alike from here.
        case unreachable(String)
    }

    /// The bundled helper's bytes, read once.
    nonisolated static let bundledHelper: Data? = {
        guard let url = Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }()

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static let bundledDigest: String? = bundledHelper.map(sha256)

    private struct PingReply: Decodable {
        let ok: Bool
        let sha256: String?
    }

    /// Pings the helper and compares its hash with the bundled helper's.
    ///
    /// A reply that is not a good ping is counted as a failure here, which
    /// tears the process down. The channel counts a request that dies, but
    /// not one answered with `ok: false`: that helper is alive, and without
    /// this a helper that refuses every ping would hold the backoff at its
    /// floor and keep the reinstall that waits for the cap from ever firing.
    nonisolated static func check(channel: SSHChannel) async -> Check {
        let line: Data
        do {
            line = try await channel.request("ping")
        } catch {
            return .unreachable("\(error)")
        }
        guard let reply = try? JSONDecoder().decode(PingReply.self, from: line), reply.ok,
              let digest = reply.sha256
        else {
            let reason = "helper did not answer ping: \(String(decoding: line.prefix(200), as: UTF8.self))"
            await channel.noteFailure(reason)
            return .unreachable(reason)
        }
        return digest == bundledDigest ? .current : .stale
    }

    /// Pings, and pushes the bundled helper unless the host already runs
    /// it. A ping that fails also pushes, because a host that has never had
    /// the helper fails its ping in exactly that way.
    nonisolated static func ensureInstalled(
        alias: String, watchAs: WatchAs, channel: SSHChannel, runner: Runner? = nil
    ) async -> RemoteHostMonitor.InstallOutcome {
        switch await check(channel: channel) {
        case .current:
            return .current
        case .stale, .unreachable:
            return await push(alias: alias, watchAs: watchAs, channel: channel, runner: runner)
        }
    }

    /// Pushes the bundled helper over a one-shot ssh of its own, then shuts
    /// the channel down, so the next request starts the helper just pushed
    /// rather than talking on to the old process.
    ///
    /// A local launch is never pushed: it already runs the bundled script,
    /// and the alias it carries names no host.
    nonisolated static func push(
        alias: String, watchAs: WatchAs, channel: SSHChannel, runner: Runner? = nil
    ) async -> RemoteHostMonitor.InstallOutcome {
        guard let helper = bundledHelper else {
            NSLog("SwarmBar: swarmbar-helper.py missing from the app bundle")
            return .failed("helper missing from the app bundle")
        }
        let run: Runner
        if let runner {
            run = runner
        } else if case .ssh = channel.launch {
            run = sshRunner
        } else {
            return .failed("a local helper is never installed")
        }
        do {
            try await run(helper, alias, watchAs)
        } catch let failure as InstallFailure {
            // Only sudo can refuse for want of a password, and only the
            // root helper is installed through sudo. Running the setup
            // command again is what restores the rule that lets it.
            if watchAs == .everyUser && Self.sudoWantsPassword(failure.stderr) {
                return .needsSetup(updateNeedsSetupMessage)
            }
            return .failed(failure.message)
        } catch {
            return .failed("helper install failed: \(error)")
        }
        await channel.shutdown()
        return .installed
    }

    /// sudo -n says one of these, depending on its version and on whether
    /// the rule it fell through to asks for a password at all.
    nonisolated static func sudoWantsPassword(_ stderr: String) -> Bool {
        stderr.contains("a password is required") || stderr.contains("a terminal is required")
    }

    /// How long the install ssh gets, end to end. `waitUntilExit()` alone is
    /// unbounded: a connection that goes half open AFTER the handshake
    /// (laptop sleep, Tailscale dropping mid transfer) is not covered by
    /// ConnectTimeout, and default TCP keepalive takes roughly two hours to
    /// notice. The host's monitor loop waits on this before it reaches the
    /// code that updates reachability, so without a bound that host never
    /// polls again and its rows freeze with no note explaining why. It is
    /// the one failure here that is silent rather than visible.
    ///
    /// 30 seconds: three times ConnectTimeout, and the transfer itself is
    /// one ssh handshake plus a small write. The ServerAlive options in
    /// HelperLaunch.sshOptions would take 45 seconds to fire, so this
    /// deadline is the effective bound; they are set anyway so ssh notices
    /// on its own if this path ever stops being the one holding the
    /// stopwatch.
    nonisolated static let installTimeout: TimeInterval = 30

    /// The real push: `HelperLaunch.installCommand` over its own ssh, with
    /// the bytes on stdin. Detached because `Process` is waited on by
    /// polling, which would otherwise hold the caller's executor for the
    /// length of an ssh round trip.
    nonisolated static let sshRunner: Runner = { helper, alias, watchAs in
        try await Task.detached { try install(data: helper, alias: alias, watchAs: watchAs) }.value
    }

    private nonisolated static func install(data: Data, alias: String, watchAs: WatchAs) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = HelperLaunch.sshOptions + [alias, HelperLaunch.installCommand(for: watchAs)]
        let stdin = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = FileHandle.nullDevice
        task.standardError = stderr
        do {
            try task.run()
            try stdin.fileHandleForWriting.write(contentsOf: data)
            try stdin.fileHandleForWriting.close()
        } catch {
            let said = SSHChannel.readAvailable(stderr.fileHandleForReading)
            let hint = Self.hint(said)
            NSLog("SwarmBar: helper install failed on \(alias): \(error)\(hint)")
            throw InstallFailure(message: "helper install failed\(hint)", stderr: String(decoding: said, as: UTF8.self))
        }

        let deadline = Date.now.addingTimeInterval(installTimeout)
        while task.isRunning && Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if task.isRunning {
            task.terminate()
            NSLog("SwarmBar: helper install timed out after \(Int(installTimeout))s on \(alias)")
            throw InstallFailure(message: "helper install timed out on \(alias)", stderr: "")
        }
        if task.terminationStatus != 0 {
            let said = SSHChannel.readAvailable(stderr.fileHandleForReading)
            let hint = Self.hint(said)
            NSLog("SwarmBar: helper install exited \(task.terminationStatus) on \(alias)\(hint)")
            throw InstallFailure(
                message: "helper install exited \(task.terminationStatus)\(hint)",
                stderr: String(decoding: said, as: UTF8.self))
        }
    }

    /// The first thing ssh said, ready to append to a message. Read without
    /// waiting for more, so it is safe even when the spawn itself failed and
    /// nothing will ever close the pipe.
    private nonisolated static func hint(_ said: Data) -> String {
        let line = SSHChannel.firstLine(of: said)
        return line.isEmpty ? "" : ": \(line)"
    }
}
