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

    func start(into store: SessionStore) async {
        let channel = SSHChannel(alias: host.alias)
        let name = host.displayName
        var installed = false

        while !Task.isCancelled {
            if !store.isPaused && host.isEnabled {
                if !installed {
                    installed = await Self.installHelper(alias: host.alias)
                }
                do {
                    let snapshot = try await channel.snapshot()
                    let now = Date.now
                    let sessions = RemoteSnapshot.sessions(from: snapshot, host: name, now: now)
                    store.sync(tool: .claudeCode, host: name, sessions: sessions)
                    store.noteRemoteReachability(host: name, .reachable)
                    if snapshot.processesFailed {
                        // An empty process list would otherwise read as
                        // "no agents running". BSD ps rejecting a GNU flag
                        // produces exactly that.
                        NSLog("SwarmBar: \(name) could not list processes: \(snapshot.warnings)")
                    }
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
                    installed = false
                    let backoff = await channel.currentBackoff
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
    nonisolated static func installHelper(alias: String) async -> Bool {
        guard let source = Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"),
              let data = try? Data(contentsOf: source)
        else {
            NSLog("SwarmBar: swarmbar-helper.py missing from the app bundle")
            return false
        }
        return await Task.detached { install(data: data, alias: alias) }.value
    }

    private nonisolated static func install(data: Data, alias: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias]
            + SSHChannel.installCommand(helperPath: "/usr/local/lib/swarmbar-helper")
        let stdin = Pipe()
        task.standardInput = stdin
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            try stdin.fileHandleForWriting.write(contentsOf: data)
            try stdin.fileHandleForWriting.close()
            task.waitUntilExit()
        } catch {
            NSLog("SwarmBar: helper install failed on \(alias): \(error)")
            return false
        }
        if task.terminationStatus != 0 {
            NSLog("SwarmBar: helper install exited \(task.terminationStatus) on \(alias)")
            return false
        }
        return true
    }
}
