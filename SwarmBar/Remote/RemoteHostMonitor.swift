import Foundation

/// One per configured host. Emits sessions for every tool that host runs,
/// rather than one monitor per tool, because a host costs one round trip
/// per tick regardless of how many sessions it holds.
///
/// Each poll checks the helper, takes a snapshot, writes it into the host's
/// mirror, and runs every local monitor's discovery against that mirror.
/// The helper ships bytes and never verdicts, so there is no second parser
/// for remote sessions.
struct RemoteHostMonitor: SessionMonitor {
    let connection: RemoteHostConnection
    let pollInterval: Duration
    let installRunner: HelperInstaller.Runner?

    /// Gentler than the local 3 seconds. Remote hosts relay through
    /// Tailscale and a snapshot is one round trip for the whole host.
    static let pollSeconds: TimeInterval = 10

    /// How often a helper that answers but is out of date gets another
    /// push. It is still being polled, so the update is not urgent, and a
    /// push that keeps failing costs one extra connection a minute rather
    /// than one a poll.
    static let staleRetry: Duration = .seconds(60)

    /// `pollInterval` and `installRunner` are for tests, which cannot wait
    /// ten seconds a poll and must never run ssh.
    init(connection: RemoteHostConnection, pollInterval: Duration = .seconds(Self.pollSeconds),
         installRunner: HelperInstaller.Runner? = nil) {
        self.connection = connection
        self.pollInterval = pollInterval
        self.installRunner = installRunner
    }

    /// Whether a failed poll should force a helper reinstall on the next
    /// attempt. A transient failure is almost never a missing helper, so
    /// reinstalling on it just doubles the connection attempts: the install
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

    /// What making sure of the helper came to.
    enum InstallOutcome: Sendable, Equatable {
        /// The host already runs the bundled helper.
        case current
        /// The bundled helper was pushed and the channel shut down, so the
        /// next request starts it.
        case installed
        /// Neither, with ssh's own words where it said any. That is the only
        /// thing that separates a missing NOPASSWD rule from an unauthorized
        /// key from a host that is simply down.
        case failed(String)
        /// sudo would not install the root helper without a password, which
        /// the setup command fixes.
        case needsSetup(String)

        var ok: Bool { self == .current || self == .installed }
    }

    /// What one host's loop carries from poll to poll.
    private struct PollState {
        /// The stream the mirror was last filled from. Nil until a snapshot
        /// has been applied in full, and again after any that was not, so
        /// the next one always starts from an empty mirror.
        var stream: String?
        /// When the helper was last pushed, so pushes are spaced out.
        var lastPush: ContinuousClock.Instant?
        /// The running helper answered with another version's hash.
        var runningStale = false
        /// Set while sudo refuses to update the helper. It stands in for
        /// reachability until the update goes through, because it is the
        /// one thing the user can act on.
        var setupNeeded: String?
        /// The previous poll's warnings, so a warning that persists (an
        /// unreadable transcript does not fix itself) is logged once rather
        /// than every ten seconds.
        var lastWarnings: [String] = []

        /// Setup can only be asked of a host that answers. When the ping,
        /// the push or the snapshot itself failed, the host reads
        /// unreachable whatever it needed before, or its rows would lose
        /// their "Cannot reach" note and Settings would ask for a setup
        /// command on a machine that is down.
        func reachability(failing reason: String, hostAnswered: Bool) -> RemoteReachability {
            guard hostAnswered, let setupNeeded else { return .unreachable(reason) }
            return .needsSetup(setupNeeded)
        }
    }

    func start(into store: SessionStore) async {
        var state = PollState()
        while !Task.isCancelled {
            var delay = pollInterval
            if !store.isPaused && connection.host.isEnabled {
                delay = await poll(into: store, state: &state)
            }
            if Task.isCancelled { break }
            try? await Task.sleep(for: delay)
        }
        // A snapshot the helper built for a poll that was then cancelled is
        // marked shipped on the far side and never reached the mirror. Ending
        // the process ends that stream with it.
        await connection.channel.shutdown()
    }

    /// One poll. Returns how long to wait before the next one.
    ///
    /// Cancel is only a request, and the supervisor clears this host's rows
    /// right after asking. Every store write is gated on it, after the last
    /// await before it, so an in-flight poll cannot bring the cleared rows
    /// back.
    private func poll(into store: SessionStore, state: inout PollState) async -> Duration {
        let host = connection.host, channel = connection.channel, mirror = connection.mirror
        let name = host.displayName

        let backoff = await channel.currentBackoff
        let check = await HelperInstaller.check(channel: channel)
        // A cancelled ping reads as unreachable, and must not set off a push.
        if Task.isCancelled { return pollInterval }
        switch check {
        case .current:
            state.setupNeeded = nil
            if state.runningStale {
                // The ping hashes the file on disk, not the code running, so
                // a helper replaced underneath an old process (the setup
                // command run again) matches while the old one still runs.
                state.runningStale = false
                await channel.shutdown()
            }
        case .stale:
            state.runningStale = true
            let now = ContinuousClock.now
            if state.lastPush.map({ now - $0 >= Self.staleRetry }) ?? true {
                state.lastPush = now
                switch await push(host, channel) {
                case .current, .installed:
                    state.runningStale = false
                    state.setupNeeded = nil
                case .needsSetup(let message):
                    state.setupNeeded = message
                case .failed(let message):
                    NSLog("SwarmBar: \(name) keeps its old helper: \(message)")
                }
            }
            // Either way the helper answers, and an old helper that still
            // speaks this protocol keeps the rows current meanwhile.
        case .unreachable(let reason):
            // A helper that was never installed fails its ping the same way
            // a host that is down does. Push on the first failure, as the
            // only way to tell, and after that only once the backoff says
            // the failure is not transient.
            guard state.lastPush == nil || Self.shouldReinstall(afterBackoff: backoff) else {
                return await failed(reason, hostAnswered: false, store: store, state: &state)
            }
            state.lastPush = ContinuousClock.now
            switch await push(host, channel) {
            case .current, .installed:
                state.setupNeeded = nil
            case .needsSetup(let message):
                // sudo answered, so the host did.
                state.setupNeeded = message
                return await failed(message, hostAnswered: true, store: store, state: &state)
            case .failed(let message):
                return await failed(message, hostAnswered: false, store: store, state: &state)
            }
        }
        if Task.isCancelled { return pollInterval }
        // Set before the snapshot, so a helper that is still the old one
        // (its push failed, or the next push is not due yet) never has keys
        // aimed through it, though its snapshot keeps the rows current.
        // Every path that leaves runningStale false has either confirmed
        // the running helper or shut the channel down so the next request
        // starts the bundled one.
        if connection.noteHelperCurrent(!state.runningStale) { store.noteRemotePanesChanged() }

        let snapshot: RemoteSnapshot
        do {
            snapshot = try await channel.snapshot()
        } catch {
            // snapshot() ends the helper on every failure it counts, so the
            // next request starts a fresh stream. A cancelled poll is ended
            // by the shutdown when the loop exits.
            if Task.isCancelled { return pollInterval }
            return await failed("\(error)", hostAnswered: false, store: store, state: &state)
        }

        // A new stream means a new helper process, which ships every file
        // relative to nothing the mirror holds. Mirror writes are disk I/O
        // and run off the main actor.
        let reset = snapshot.stream != state.stream
        let mirrorWarnings: [String]
        do {
            mirrorWarnings = try await Task.detached {
                if reset { try mirror.reset() }
                return try mirror.apply(snapshot)
            }.value
        } catch {
            // The helper believes it shipped bytes the mirror does not hold,
            // and its next growth chunk would land on top of the gap. Only a
            // fresh helper and an empty mirror recover from that, and this
            // is counted as a failure so a disk that keeps refusing backs off
            // rather than taking a full reship every poll.
            NSLog("SwarmBar: \(name) mirror write failed: \(error)")
            state.stream = nil
            await channel.noteFailure("mirror: \(error)")
            if Task.isCancelled { return pollInterval }
            // The host answered; it is this Mac's disk that refused.
            return await failed("\(error)", hostAnswered: true, store: store, state: &state)
        }
        state.stream = snapshot.stream

        // Off the main actor, exactly as the local monitors run their own
        // discovery: it is on the order of a megabyte of string work.
        let now = Date.now, hostID = host.id
        let result = await Task.detached {
            RemoteDiscovery.discover(
                snapshot: snapshot, mirror: mirror, hostID: hostID, hostName: name, now: now)
        }.value
        if Task.isCancelled { return pollInterval }

        if connection.noteApplied(snapshot) { store.noteRemotePanesChanged() }
        // A tool this pass cannot vouch for keeps its previous rows. Its
        // sessions may only be missing because the evidence could not be
        // read, and syncing would turn "could not look" into "nothing there".
        for tool in AgentTool.allCases where !result.unverifiedTools.contains(tool) {
            store.sync(tool: tool, host: name, sessions: result.sessions[tool] ?? [])
        }
        store.noteRemoteReachability(host: name, state.setupNeeded.map { .needsSetup($0) } ?? .reachable)

        // The helper's own warnings (a backup-looking root skipped, a record
        // beyond the 4 MB ceiling omitted), chunks the mirror refused, and
        // what discovery could not see, including a failed process list.
        // Logged only when the set changes, not every poll while the same
        // condition persists.
        let warnings = snapshot.warnings + mirrorWarnings + result.warnings
        if !warnings.isEmpty && warnings != state.lastWarnings {
            NSLog("SwarmBar: \(name) reported warnings: \(warnings)")
        }
        state.lastWarnings = warnings
        return pollInterval
    }

    private func push(_ host: RemoteHost, _ channel: SSHChannel) async -> InstallOutcome {
        await HelperInstaller.push(
            alias: host.alias, watchAs: host.watchAs, channel: channel, runner: installRunner)
    }

    /// Deliberately does NOT clear this host's sessions, though it does
    /// forget the last snapshot's panes (see RemoteHostConnection.noteLost). The work is still
    /// running on the far side and SwarmBar has simply gone blind, so
    /// marking it ended would be a lie and dropping it would look like the
    /// work finished. Nor does it clear the mirror: the next helper process
    /// is a new stream, and that is what resets it.
    private func failed(
        _ reason: String, hostAnswered: Bool, store: SessionStore, state: inout PollState
    ) async -> Duration {
        state.stream = nil
        // Unlike the rows, the pane map is not kept: keys aimed by it after
        // a gap could land in whatever now owns the pane.
        if connection.noteLost() { store.noteRemotePanesChanged() }
        let backoff = await connection.channel.currentBackoff
        if Task.isCancelled { return pollInterval }
        store.noteRemoteReachability(
            host: connection.host.displayName, state.reachability(failing: reason, hostAnswered: hostAnswered))
        return .seconds(backoff)
    }
}
