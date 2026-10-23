import Foundation
import Synchronization

/// A remote host's sessions, found by running every local monitor's own
/// discovery against that host's mirror. Nothing here reads agent state
/// itself: the mirror holds the host's files at their own paths, the
/// process table answers the liveness questions, and the monitors do the
/// rest exactly as they do for this Mac.
enum RemoteDiscovery {
    struct Result: Sendable {
        /// Every tool, always, so a tool that vanished from the host clears
        /// its rows rather than leaving them behind.
        var sessions: [AgentTool: [AgentSession]]
        /// What discovery could not see: homes and session directories the
        /// mirror refused, and process records whose open files could not
        /// be read. Worth logging, because each can hide a running session.
        var warnings: [String]
        /// True when the host's ps failed, so no row could be confirmed
        /// alive.
        var processesFailed: Bool
        /// Tools whose rows this pass cannot vouch for. Callers must NOT
        /// sync an unverified tool: they keep its previous rows instead.
        /// Its sessions here may read as ended, or be missing outright,
        /// only because the evidence of liveness could not be read, and
        /// syncing them would turn "could not look" into "nothing there".
        ///
        /// Codex and Antigravity know a session is alive only from the
        /// files its process holds, so one of their processes with
        /// unreadable open files leaves that tool unverified. A failed
        /// process list leaves every tool unverified.
        var unverifiedTools: Set<AgentTool>
    }

    /// Which process name proves liveness for a tool through held files
    /// alone. A process of that name whose open files are unknown makes
    /// the tool's whole result unverifiable.
    private nonisolated static let heldFileTools: [String: AgentTool] = [
        "codex": .codex,
        "agy": .antigravity,
    ]

    nonisolated static func sessions(
        snapshot: RemoteSnapshot, mirror: RemoteMirror, hostID: UUID, hostName: String, now: Date
    ) -> [AgentTool: [AgentSession]] {
        discover(snapshot: snapshot, mirror: mirror, hostID: hostID, hostName: hostName, now: now)
            .sessions
    }

    /// Reads only the snapshot and the mirror and keeps no state of its
    /// own. The monitors it calls do update their shared tail caches, but
    /// each pass evicts only beneath the roots it scanned, so passes for
    /// this Mac and for every remote home run side by side without
    /// disturbing one another. Safe to run detached.
    nonisolated static func discover(
        snapshot: RemoteSnapshot, mirror: RemoteMirror, hostID: UUID, hostName: String, now: Date
    ) -> Result {
        var warnings: [String] = []
        var unverified: Set<AgentTool> = []
        if snapshot.processesFailed {
            warnings.append("process list unavailable, so no remote session can be confirmed alive")
            unverified = Set(AgentTool.allCases)
        }
        var found = Dictionary(uniqueKeysWithValues: AgentTool.allCases.map { ($0, [AgentSession]()) })
        let refused = RefusedPaths()

        for home in snapshot.homes {
            guard let local = mirror.local(home.path) else {
                warnings.append("skipped home \(home.path): it cannot be mapped into the mirror")
                continue
            }
            // Only the home's own user's processes. A root process sharing
            // a working directory with a session under /home/u must not
            // mark that session alive or lend it a pid.
            let records = snapshot.processes.filter { $0.user == home.user }
            let facts = RemoteProcessFacts(
                processes: records, failed: snapshot.processesFailed, mirror: mirror)
            warnings += facts.unreadablePids.map {
                "open files of pid \($0) unknown, so sessions it holds may read as ended"
            }
            for record in records where record.openFailed && !snapshot.processesFailed {
                if let tool = heldFileTools[record.comm] { unverified.insert(tool) }
            }

            let context = DiscoveryContext(
                home: local,
                processes: facts,
                // Kimi's index names its session directories by their path
                // on the host. One the mirror refuses is pointed at a path
                // that is never a directory, so that session is skipped
                // rather than read from somewhere it does not live, and the
                // refusal is reported.
                locate: { path in
                    if let mapped = mirror.local(path) { return mapped }
                    refused.add(path)
                    return URL(fileURLWithPath: "/dev/null")
                },
                screen: { facts.screen(pid: $0) },
                resolvesPids: true)
            for (tool, sessions) in discoverAll(now: now, context: context) {
                found[tool, default: []] += sessions
            }
        }
        warnings += refused.paths.map {
            "skipped session directory \($0): it cannot be mapped into the mirror"
        }

        let sessions = found.mapValues { rows in
            rows.map {
                $0.withID(RemoteIdentity.sessionID(hostID: hostID, localID: $0.id), host: hostName)
            }
        }
        return Result(
            sessions: sessions, warnings: warnings,
            processesFailed: snapshot.processesFailed, unverifiedTools: unverified)
    }

    private nonisolated static func discoverAll(
        now: Date, context: DiscoveryContext
    ) -> [AgentTool: [AgentSession]] {
        [
            .claudeCode: ClaudeCodeMonitor.discover(now: now, context: context),
            .codex: CodexMonitor.discover(now: now, context: context),
            .kimiCode: KimiMonitor.discover(now: now, context: context, tool: .kimiCode),
            .bearCode: KimiMonitor.discover(now: now, context: context, tool: .bearCode),
            .openCode: OpenCodeMonitor.discover(now: now, context: context),
            .grokBuild: GrokBuildMonitor.discover(now: now, context: context),
            .antigravity: AntigravityMonitor.discover(now: now, context: context),
        ]
    }

    /// Paths `locate` refused, collected from inside a `@Sendable` closure.
    private final class RefusedPaths: Sendable {
        private let storage = Mutex<[String]>([])

        nonisolated func add(_ path: String) {
            storage.withLock { $0.append(path) }
        }

        nonisolated var paths: [String] {
            storage.withLock { $0 }
        }
    }
}
