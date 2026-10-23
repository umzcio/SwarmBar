import Foundation

/// The wizard's verdict on one host: Ready, Needs setup (with every reason),
/// or Can't connect. Pure, so the whole table of cases is unit tested
/// against synthetic probes.
struct HostAssessment: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ready
        case needsSetup([String])
        case cantConnect(HostProblem)
    }

    var status: Status
    /// What the wizard pre-selects. nil means the user has to pick: no
    /// passwordless sudo and agents here run as someone else, or the
    /// process list could not be read so nobody knows who runs them.
    var suggestedWatchAs: WatchAs?
    var summary: String
    /// Agents another user runs, which a host watched as the login user
    /// cannot show. nil when the process list could not be read.
    var hiddenSessions: Int?

    static let pickReason = "Agents here run as root. Pick how SwarmBar should watch this host."
    /// Watching every user without passwordless sudo needs the narrow sudo
    /// rule and root's copy of the helper, which only the setup command or
    /// the paste path can put in place.
    static let sudoRuleReason =
        "Watching every user needs a one-time sudo rule. Run the setup command."
    /// Root's helper is there, but running it through the narrow rule gave
    /// no view of every user: the rule is missing, or the helper is too old
    /// to probe.
    static let narrowProbeFailedReason =
        "SwarmBar can't look at the other users' sessions yet. Run the setup command."
    /// sudo worked for the login user, yet no root view came back.
    static let rootViewMissingReason =
        "SwarmBar couldn't look at every user's sessions on this host. Check again."
    static let processesFailedReason = "SwarmBar couldn't list the processes on this host. Check again."
    static let noAgents = "No agents running"
    /// ps failed on the host. Not "No agents running": could not look is
    /// not the same as nothing there.
    static let processesUnknown = "Couldn't list running agents"

    /// The tools whose approvals need something installed on the host.
    /// Codex and Grok are answered with keystrokes and Antigravity is walked
    /// by label, so nothing is installed for them.
    static let toolsWithBridges: [AgentTool] = [.claudeCode, .kimiCode, .bearCode, .openCode]

    static func missingBridgeReason(_ tool: AgentTool) -> String {
        "\(tool.label) approvals not set up"
    }

    static func unreadableBridgeReason(_ tool: AgentTool) -> String {
        "SwarmBar couldn't read the \(tool.label) config on this host. Check again."
    }

    /// `user` is the login user's view. `root` is the view of every user,
    /// through `sudo -n` or the narrow sudo rule, when one came back.
    /// `failure` is why a probe failed: the login user's, or root's after
    /// the login user's worked. `watchAs` is the user's pick, nil until they
    /// make one. `helperSHA256` is this build's helper, which an installed
    /// root helper must match.
    static func assess(
        user: ProbeResult?, root: ProbeResult?, failure: HostProblem?, watchAs: WatchAs?,
        helperSHA256: String? = HelperInstaller.bundledDigest
    ) -> HostAssessment {
        guard let user else {
            return HostAssessment(status: .cantConnect(failure ?? .other("No answer from the host")),
                                  suggestedWatchAs: nil, summary: "", hiddenSessions: nil)
        }

        // A failed ps says nothing about who runs the agents, so it cannot
        // drive the pick either way.
        let processesKnown = !user.processesFailed
        let suggested: WatchAs?
        if !processesKnown {
            suggested = nil
        } else if user.sudoOK {
            suggested = .everyUser
        } else if user.processes.allSatisfy({ $0.user == user.user }) {
            suggested = .loginUser
        } else {
            suggested = nil
        }
        let chosen = watchAs ?? suggested
        // A failure after the login user's probe worked is root's. It only
        // matters when root's view is the one being watched.
        if let failure, chosen != .loginUser {
            return HostAssessment(status: .cantConnect(failure), suggestedWatchAs: suggested, summary: "",
                                  hiddenSessions: nil)
        }

        var reasons: [String] = []
        var effective = user
        // Watching every user is only ever judged on a view of every user.
        // Without one, the login user's view would vouch for homes it cannot
        // see, so the host is never Ready.
        var judgeTools = true
        if chosen == .everyUser {
            if let root {
                effective = root
            } else {
                judgeTools = false
                if user.sudoOK {
                    reasons.append(rootViewMissingReason)
                } else if user.helper.contains(where: { $0.path == HelperLaunch.rootHelperPath }) {
                    reasons.append(narrowProbeFailedReason)
                } else {
                    reasons.append(sudoRuleReason)
                }
            }
        }
        if !processesKnown || effective.processesFailed {
            reasons.insert(processesFailedReason, at: 0)
        } else if chosen == nil {
            reasons.insert(pickReason, at: 0)
        }
        if judgeTools {
            for tool in toolsWithBridges {
                if let reason = bridgeReason(tool, in: effective) { reasons.append(reason) }
            }
        }
        // Under the narrow rule the root view came from root's installed
        // helper, which says what it is. Unreadable (root's 700 file, seen
        // without sudo) is unknown, not stale.
        if chosen == .everyUser && !user.sudoOK {
            let installed = [root?.selfSHA256]
                + user.helper.filter { $0.path == HelperLaunch.rootHelperPath }.map(\.sha256)
            if installed.contains(where: { $0 != nil && $0 != helperSHA256 }) {
                reasons.append(HelperInstaller.updateNeedsSetupMessage)
            }
        }

        let hidden: Int? = !processesKnown ? nil
            : chosen == .loginUser ? user.processes.filter { $0.user != user.user }.count : 0
        return HostAssessment(
            status: reasons.isEmpty ? .ready : .needsSetup(reasons),
            suggestedWatchAs: suggested,
            summary: summary(of: effective),
            hiddenSessions: hidden)
    }

    /// Why a tool's approvals are not ready in any watched home, if they
    /// are not: its bridge is missing, or a config that would say is
    /// unreadable.
    private static func bridgeReason(_ tool: AgentTool, in probe: ProbeResult) -> String? {
        var unreadable = false
        for home in probe.homes {
            let tools = { (names: [String]?) in (names ?? []).compactMap(ProbeResult.tool(named:)) }
            guard tools(probe.tools[home.path]).contains(tool),
                  !tools(probe.installed[home.path]).contains(tool) else { continue }
            if tools(probe.installedUnknown[home.path]).contains(tool) {
                unreadable = true
            } else {
                return missingBridgeReason(tool)
            }
        }
        return unreadable ? unreadableBridgeReason(tool) : nil
    }

    /// "3 Claude Code, 1 Kimi Code, 1 Grok Build": counts in AgentTool
    /// order, so every host's line reads the same way round.
    static func summary(of probe: ProbeResult) -> String {
        if probe.processesFailed { return processesUnknown }
        var counts: [AgentTool: Int] = [:]
        for process in probe.processes {
            if let tool = ProbeResult.tool(forProcess: process.comm) { counts[tool, default: 0] += 1 }
        }
        let parts = AgentTool.allCases.compactMap { tool in
            counts[tool].map { "\($0) \(tool.label)" }
        }
        return parts.isEmpty ? noAgents : parts.joined(separator: ", ")
    }
}
