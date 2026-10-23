import Foundation

/// The empty popover's pointer at remote host setup. It only appears when it
/// could plausibly help: nothing is showing, no hosts are configured, and the
/// user's ssh config names at least one machine that might be running agents.
enum RemoteHostHint {
    /// Configured hosts suppress the hint even when all of them are
    /// unreachable, since the user has already found the feature.
    static func shouldShow(visibleSessions: Int, configuredHosts: Int, candidateAliases: Int) -> Bool {
        visibleSessions == 0 && configuredHosts == 0 && candidateAliases > 0
    }

    /// Aliases that are plainly git forges, matched by name only. The wizard
    /// resolves hosts with `ssh -G` for a fuller filter; the popover must not
    /// spawn a process just to decide whether to show a line of text.
    static func countCandidates(in aliases: [String]) -> Int {
        aliases.filter { !HostCandidates.gitHosts.contains($0.lowercased()) }.count
    }

    /// Reads `~/.ssh/config` and counts candidate aliases. A missing or
    /// unreadable file counts as zero, which hides the hint: the safe
    /// direction for something optional.
    static func readCandidateCount(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Int {
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        let config = ssh.appendingPathComponent("config")
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        guard let text = read(config) else { return 0 }
        let aliases = SSHConfigParser.aliases(
            in: text, baseDirectory: ssh, home: home, read: read)
        return countCandidates(in: aliases)
    }
}

/// Caches the candidate count for a minute so reopening the popover does not
/// reparse the config every time.
actor RemoteHostCandidateCache {
    static let shared = RemoteHostCandidateCache()

    private var value: (count: Int, at: Date)?
    private let ttl: TimeInterval = 60

    func count(now: Date = Date(), compute: @Sendable () -> Int = { RemoteHostHint.readCandidateCount() }) -> Int {
        if let value, now.timeIntervalSince(value.at) < ttl { return value.count }
        let fresh = compute()
        value = (fresh, now)
        return fresh
    }
}
