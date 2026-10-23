import Foundation

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
        /// What discovery could not see: homes the mirror refused and
        /// process records it could not read. Worth logging, because each
        /// one can make a running session look ended.
        var warnings: [String]
        /// True when the host's ps failed, so no row could be confirmed
        /// alive. Every row then reads as ended, which is a statement about
        /// what could be seen and not about the sessions themselves.
        var processesFailed: Bool
    }

    nonisolated static func sessions(
        snapshot: RemoteSnapshot, mirror: RemoteMirror, hostID: UUID, hostName: String, now: Date
    ) -> [AgentTool: [AgentSession]] {
        discover(snapshot: snapshot, mirror: mirror, hostID: hostID, hostName: hostName, now: now)
            .sessions
    }

    /// Pure apart from reading the mirror, so it is safe to run detached.
    nonisolated static func discover(
        snapshot: RemoteSnapshot, mirror: RemoteMirror, hostID: UUID, hostName: String, now: Date
    ) -> Result {
        let facts = RemoteProcessFacts(
            processes: snapshot.processes, failed: snapshot.processesFailed, mirror: mirror)
        var warnings = facts.warnings
        var found = Dictionary(uniqueKeysWithValues: AgentTool.allCases.map { ($0, [AgentSession]()) })

        for home in snapshot.homes {
            guard let local = mirror.local(home.path) else {
                warnings.append("skipped home \(home.path): it cannot be mapped into the mirror")
                continue
            }
            let context = DiscoveryContext(
                home: local,
                processes: facts,
                // Kimi's index names its session directories by their path
                // on the host. One the mirror refuses is pointed at a path
                // that is never a directory, so that session is skipped
                // rather than read from somewhere it does not live.
                locate: { mirror.local($0) ?? URL(fileURLWithPath: "/dev/null") },
                screen: { facts.screen(pid: $0) },
                resolvesPids: true)
            for (tool, sessions) in discoverAll(now: now, context: context) {
                found[tool, default: []] += sessions
            }
        }

        let sessions = found.mapValues { rows in
            rows.map { rekeyed($0, hostID: hostID, hostName: hostName) }
        }
        return Result(sessions: sessions, warnings: warnings, processesFailed: snapshot.processesFailed)
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

    /// `id` is a constant on AgentSession, so the row is rebuilt with every
    /// other field carried across unchanged.
    private nonisolated static func rekeyed(
        _ session: AgentSession, hostID: UUID, hostName: String
    ) -> AgentSession {
        AgentSession(
            id: RemoteIdentity.sessionID(hostID: hostID, localID: session.id),
            tool: session.tool,
            projectName: session.projectName,
            projectPath: session.projectPath,
            status: session.status,
            startedAt: session.startedAt,
            lastActivityAt: session.lastActivityAt,
            pid: session.pid,
            accountLabel: session.accountLabel,
            title: session.title,
            processAlive: session.processAlive,
            host: hostName,
            attentionEventID: session.attentionEventID)
    }
}
