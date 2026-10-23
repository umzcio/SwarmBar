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
    /// passwordless sudo, and agents here run as someone else.
    var suggestedWatchAs: WatchAs?
    var summary: String
    /// Agents another user runs, which a host watched as the login user
    /// cannot show.
    var hiddenSessions: Int

    static let pickReason = "Agents here run as root. Pick how SwarmBar should watch this host."
    /// Watching every user without passwordless sudo needs the narrow sudo
    /// rule and root's copy of the helper, which only the setup command or
    /// the paste path can put in place.
    static let sudoRuleReason =
        "Watching every user needs a one-time sudo rule. Run the setup command."
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

    /// `user` is the login user's view and `root` the same probe under sudo,
    /// present only when `sudo -n` worked. `watchAs` is the user's pick, nil
    /// until they make one. `helperSHA256` is this build's helper, which an
    /// installed root helper must match.
    static func assess(
        user: ProbeResult?, root: ProbeResult?, failure: HostProblem?, watchAs: WatchAs?,
        helperSHA256: String? = HelperInstaller.bundledDigest
    ) -> HostAssessment {
        if let failure {
            return HostAssessment(status: .cantConnect(failure), suggestedWatchAs: nil, summary: "",
                                  hiddenSessions: 0)
        }
        guard let user else {
            return HostAssessment(status: .cantConnect(.other("No answer from the host")),
                                  suggestedWatchAs: nil, summary: "", hiddenSessions: 0)
        }

        let suggested: WatchAs?
        if user.sudoOK {
            suggested = .everyUser
        } else if user.processes.allSatisfy({ $0.user == user.user }) {
            suggested = .loginUser
        } else {
            suggested = nil
        }
        let chosen = watchAs ?? suggested
        // Only root sees every home. Without sudo the login user's view is
        // all there is, even when the pick is every user.
        let effective = chosen == .everyUser && user.sudoOK ? (root ?? user) : user

        var reasons: [String] = []
        if chosen == nil { reasons.append(pickReason) }
        for tool in toolsWithBridges where effective.homes.contains(where: { home in
            let present = effective.tools[home.path, default: []].compactMap(ProbeResult.tool(named:))
            let installed = effective.installed[home.path, default: []].compactMap(ProbeResult.tool(named:))
            return present.contains(tool) && !installed.contains(tool)
        }) {
            reasons.append(missingBridgeReason(tool))
        }
        if chosen == .everyUser && !user.sudoOK {
            if let installed = user.helper.first(where: { $0.path == HelperLaunch.rootHelperPath }) {
                // Unreadable (root's 700 file, seen without sudo) is unknown,
                // not stale: the monitor's own ping says so once it runs.
                if let sha = installed.sha256, sha != helperSHA256 {
                    reasons.append(HelperInstaller.updateNeedsSetupMessage)
                }
            } else {
                reasons.append(sudoRuleReason)
            }
        }

        let hidden = chosen == .loginUser ? user.processes.filter { $0.user != user.user }.count : 0
        return HostAssessment(
            status: reasons.isEmpty ? .ready : .needsSetup(reasons),
            suggestedWatchAs: suggested,
            summary: summary(of: effective),
            hiddenSessions: hidden)
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
