import Foundation

/// One per configured host. Emits sessions for every tool that host runs,
/// rather than one monitor per tool, because a host costs one round trip
/// per tick regardless of how many sessions it holds.
///
/// Phase 1a covers Claude Code only. The helper's protocol version gates
/// what later phases add, and a version bump is a redeploy rather than a
/// migration.
struct RemoteHostMonitor: SessionMonitor {
    let host: RemoteHost

    /// Gentler than the local 3 seconds. Remote hosts relay through
    /// Tailscale and a snapshot is one round trip for the whole host.
    static let pollSeconds: TimeInterval = 10

    /// Whether a failed poll should force a helper reinstall on the next
    /// attempt. A transient failure is almost never a missing helper, so
    /// reinstalling on it just doubles the connection attempts: installHelper
    /// spawns its own ssh, and the snapshot retry that follows spawns a
    /// second one, each with its own ConnectTimeout, against a host that may
    /// be down precisely because it is flaky or access-controlled. A host
    /// that has failed long enough to saturate the backoff is the case where
    /// "the helper is broken" becomes plausible, and at the cap a reinstall
    /// costs one extra connection per minute rather than one per cycle. That
    /// keeps self-healing without the doubling.
    nonisolated static func shouldReinstall(afterBackoff backoff: Int) -> Bool {
        backoff >= 60
    }

    func start(into store: SessionStore) async {
        let channel = SSHChannel(alias: host.alias)
        let name = host.displayName
        var installed = false
        // The warning set from the previous successful snapshot for this
        // host, so a warning that persists across polls (the common case:
        // a backup-looking root or an unreadable transcript does not fix
        // itself) is logged once rather than every ten seconds.
        var lastWarnings: [String] = []

        while !Task.isCancelled {
            if !store.isPaused && host.isEnabled {
                if !installed {
                    let outcome = await Self.installHelper(alias: host.alias)
                    installed = outcome.ok
                    if !outcome.ok {
                        // The snapshot below still runs: the helper may
                        // already be installed from an earlier session, and
                        // a successful poll overwrites this in the same
                        // iteration. What this buys is a reason on the row
                        // when the poll fails too.
                        store.noteRemoteReachability(host: name, .unreachable(outcome.message))
                    }
                }
                do {
                    let snapshot = try await channel.snapshot()
                    let now = Date.now
                    // Off the main actor, exactly as ClaudeCodeMonitor.start
                    // does with its own discovery. This splits every tail on
                    // newlines and runs JSONSerialization over the trailing
                    // lines, on the order of a megabyte of string work, and
                    // the SessionMonitor protocol is @MainActor.
                    let sessions = await Task.detached {
                        RemoteSnapshot.sessions(from: snapshot, host: name, now: now)
                    }.value
                    store.sync(tool: .claudeCode, host: name, sessions: sessions)
                    store.noteRemoteReachability(host: name, .reachable)
                    if snapshot.processesFailed {
                        // An empty process list would otherwise read as
                        // "no agents running". BSD ps rejecting a GNU flag
                        // produces exactly that.
                        NSLog("SwarmBar: \(name) could not list processes: \(snapshot.warnings)")
                    } else if !snapshot.warnings.isEmpty && snapshot.warnings != lastWarnings {
                        // Warnings unrelated to ps: a backup-looking root
                        // the helper skipped, an unreadable transcript, or a
                        // record beyond the 4 MB ceiling omitted rather than
                        // shipped empty. None of those set processesFailed,
                        // so without this branch they were silent on the
                        // Mac. Logged only when the set changes from the
                        // previous snapshot for this host, not on every
                        // poll while the same condition persists.
                        NSLog("SwarmBar: \(name) reported warnings: \(snapshot.warnings)")
                    }
                    lastWarnings = snapshot.warnings
                } catch {
                    // Deliberately does NOT clear this host's sessions. The
                    // work is still running on the far side and SwarmBar has
                    // simply gone blind, so marking it ended would be a lie
                    // and dropping it would look like the work finished.
                    //
                    // Deliberately does NOT call channel.noteFailure either.
                    // snapshot() routes its own failures through it, so a
                    // second call here would double-count and double the
                    // backoff on every failure. This block only mirrors the
                    // state into the store for the UI.
                    store.noteRemoteReachability(host: name, .unreachable("\(error)"))
                    let backoff = await channel.currentBackoff
                    if Self.shouldReinstall(afterBackoff: backoff) {
                        installed = false
                    }
                    try? await Task.sleep(for: .seconds(backoff))
                    continue
                }
            }
            try? await Task.sleep(for: .seconds(Self.pollSeconds))
        }
        await channel.shutdown()
    }

    /// Pushes the helper over the same ssh connection rather than a
    /// separate scp step, so there is only ever one channel to authorize.
    /// Idempotent: `install` overwrites, so a redeploy is safe.
    /// `nonisolated` and detached on purpose. `RemoteHostMonitor` conforms
    /// to the `@MainActor` `SessionMonitor` protocol, and `waitUntilExit()`
    /// blocks, so running this on the main actor would freeze the popover
    /// for the length of an ssh round trip.
    nonisolated static func installHelper(alias: String) async -> InstallOutcome {
        guard let source = Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"),
              let data = try? Data(contentsOf: source)
        else {
            NSLog("SwarmBar: swarmbar-helper.py missing from the app bundle")
            return InstallOutcome(ok: false, message: "helper missing from the app bundle")
        }
        return await Task.detached { install(data: data, alias: alias) }.value
    }

    /// Whether the install worked, and what went wrong if it did not. The
    /// message carries ssh's own first stderr line, which is the only thing
    /// that separates a missing NOPASSWD rule from an unauthorized key from
    /// a host that is simply down.
    struct InstallOutcome: Sendable {
        let ok: Bool
        let message: String
    }

    /// How long the install ssh gets, end to end. `waitUntilExit()` alone is
    /// unbounded: a connection that goes half open AFTER the handshake
    /// (laptop sleep, Tailscale dropping mid transfer) is not covered by
    /// ConnectTimeout, and default TCP keepalive takes roughly two hours to
    /// notice. This whole function then blocks the host's monitor loop
    /// BEFORE its do/catch, so that host never polls, never updates
    /// reachability, and its rows freeze with no note explaining why. It is
    /// the one failure here that is silent rather than visible.
    ///
    /// 30 seconds: three times ConnectTimeout, and the transfer itself is
    /// one ssh handshake plus a 9 KB write. The ServerAlive options below
    /// would take 45 seconds to fire, so this deadline is the effective
    /// bound; they are set anyway so ssh notices on its own if this path
    /// ever stops being the one holding the stopwatch.
    nonisolated static let installTimeout: TimeInterval = 30

    private nonisolated static func install(data: Data, alias: String) -> InstallOutcome {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            alias,
        ] + SSHChannel.installCommand(helperPath: "/usr/local/lib/swarmbar-helper")
        let stdin = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = FileHandle.nullDevice
        task.standardError = stderr
        do {
            try task.run()
            try stdin.fileHandleForWriting.write(contentsOf: data)
            try stdin.fileHandleForWriting.close()
        } catch {
            let hint = Self.stderrHint(stderr)
            NSLog("SwarmBar: helper install failed on \(alias): \(error) \(hint)")
            return InstallOutcome(ok: false, message: "helper install failed\(hint)")
        }

        let deadline = Date.now.addingTimeInterval(installTimeout)
        while task.isRunning && Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if task.isRunning {
            task.terminate()
            NSLog("SwarmBar: helper install timed out after \(Int(installTimeout))s on \(alias)")
            return InstallOutcome(
                ok: false, message: "helper install timed out on \(alias)")
        }
        if task.terminationStatus != 0 {
            let hint = Self.stderrHint(stderr)
            NSLog("SwarmBar: helper install exited \(task.terminationStatus) on \(alias)\(hint)")
            return InstallOutcome(
                ok: false,
                message: "helper install exited \(task.terminationStatus)\(hint)")
        }
        return InstallOutcome(ok: true, message: "")
    }

    /// Reads what ssh has already said, without waiting for more. Never
    /// blocks, so it is safe even when the spawn itself failed and nothing
    /// will ever close the pipe.
    private nonisolated static func stderrHint(_ pipe: Pipe) -> String {
        let line = SSHChannel.firstLine(of: SSHChannel.readAvailable(pipe.fileHandleForReading))
        return line.isEmpty ? "" : ": \(line)"
    }
}
