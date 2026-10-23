import Foundation

/// What `python3 - probe` reported about a host: the helper run once, from
/// stdin, before anything is installed there. Read-only on the host, and the
/// only input the setup wizard's assessment and plan have.
struct ProbeResult: Decodable, Sendable, Equatable {
    /// An agent config file the setup plan may edit, read as it stood when
    /// the probe ran. `text` is nil when the file was too big or not UTF-8,
    /// and the plan cannot edit what it did not read.
    struct ConfigFile: Decodable, Sendable, Equatable {
        var tool: String
        /// Resolved through symlinks, so profiles sharing one file name it once.
        var path: String
        var sha256: String
        var text: String?
    }

    /// An installed copy of SwarmBar's helper. `sha256` is nil when the file
    /// is there but this view cannot read it, which is the normal state of
    /// root's mode 700 copy seen without sudo.
    struct HelperFile: Decodable, Sendable, Equatable {
        var path: String
        var sha256: String?
    }

    /// The ssh alias that was probed. Set by the runner, never by the host.
    var alias: String = ""
    var protocolVersion: Int = 3
    var system: String = "Linux"
    var python: String = "3.12.3"
    var hostname: String = ""
    /// The account the probe ran as: the login user, or root under sudo.
    var user: String
    var euid: Int
    var sudoOK: Bool
    var homes: [RemoteHome]
    var processes: [RemoteProcessRecord]
    /// True when ps failed, so an empty `processes` is unknown, not none.
    var processesFailed: Bool = false
    /// Keyed by home path: which tools have their state directory there.
    var tools: [String: [String]]
    /// Keyed by home path: which tools' remote bridges are in place there.
    var installed: [String: [String]]
    var configs: [String: [ConfigFile]] = [:]
    var helper: [HelperFile] = []
    var warnings: [String] = []

    enum CodingKeys: String, CodingKey {
        case system, python, hostname, user, euid, homes, processes, tools, installed, configs, helper,
             warnings
        case protocolVersion = "protocol"
        case sudoOK = "sudo_ok"
        case processesFailed = "processes_failed"
    }

    /// The helper's tool names, as in its SPECS table and the probe's
    /// `tools`, `installed` and `configs`.
    static func tool(named name: String) -> AgentTool? {
        switch name {
        case "claude": .claudeCode
        case "codex": .codex
        case "kimi": .kimiCode
        case "bearcode": .bearCode
        case "opencode": .openCode
        case "grok": .grokBuild
        case "antigravity": .antigravity
        default: nil
        }
    }

    /// A process's resolved name, the way discovery maps it: both Kimi
    /// binaries are Kimi Code, and Antigravity's CLI is `agy`.
    static func tool(forProcess comm: String) -> AgentTool? {
        switch comm {
        case "claude": .claudeCode
        case "codex": .codex
        case "kimi", "kimi-code": .kimiCode
        case "bearcode": .bearCode
        case "opencode": .openCode
        case "grok": .grokBuild
        case "agy": .antigravity
        default: nil
        }
    }

    /// The probe's own failure report: `{"ok": false, "error": ...}`. Read
    /// before the full decode, which would only say a field was missing.
    struct Envelope: Decodable {
        var ok: Bool
        var error: String?
    }
}
