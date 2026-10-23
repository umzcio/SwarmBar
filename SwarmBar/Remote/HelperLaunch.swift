import Foundation

/// How a helper process is started. The two ssh modes differ only in whose
/// eyes the helper sees through: as root via sudo it reads every user's
/// agent state, and as the login user it needs no sudo at all but sees only
/// that account's sessions. The local mode runs the bundled script under a
/// local python so tests exercise the real helper and the real channel
/// without a network or a remote host.
enum HelperLaunch: Sendable, Equatable {
    case ssh(alias: String, watchAs: WatchAs)
    case local(python: String, script: String, homes: [String])

    /// Where the root helper lives. Outside any home, owned by root and
    /// mode 700, because sudo runs it as root and a user-writable copy
    /// would be a privilege escalation for anyone who can write that file.
    static let rootHelperPath = "/usr/local/lib/swarmbar-helper"

    /// The same options every ssh SwarmBar starts carries. BatchMode turns
    /// a password or passphrase prompt into a failure with a message rather
    /// than a hang nobody can answer, and the keepalives let ssh notice a
    /// half-open connection on its own instead of after TCP's two hours.
    static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
    ]

    var executable: String {
        switch self {
        case .ssh: "/usr/bin/ssh"
        case .local(let python, _, _): python
        }
    }

    var arguments: [String] {
        switch self {
        case .ssh(let alias, .everyUser):
            Self.sshOptions + [alias, "sudo", "-n", Self.rootHelperPath]
        case .ssh(let alias, .loginUser):
            // One string on purpose: ssh hands it to the remote login shell,
            // which is what expands $HOME. Split into separate arguments, the
            // quotes would arrive literally.
            Self.sshOptions + [alias, #"exec python3 "$HOME/.swarmbar/swarmbar-helper""#]
        case .local(_, let script, _):
            [script]
        }
    }

    /// nil inherits SwarmBar's own environment, which is what ssh needs to
    /// find the agent socket. The local mode replaces it outright so the
    /// helper only ever reads the homes a test hands it.
    var environment: [String: String]? {
        switch self {
        case .ssh: nil
        case .local(_, _, let homes): ["SWARMBAR_HELPER_HOMES": homes.joined(separator: ":")]
        }
    }

    /// The remote command that installs the helper from its stdin. Pushed
    /// over the same ssh connection rather than a separate scp step, so
    /// there is only ever one channel to authorize. Idempotent: `install`
    /// overwrites, so a redeploy is safe.
    static func installCommand(for watchAs: WatchAs) -> String {
        switch watchAs {
        case .everyUser:
            "sudo -n install -m 700 -o root -g root /dev/stdin \(rootHelperPath)"
        case .loginUser:
            #"mkdir -p "$HOME/.swarmbar" && chmod 700 "$HOME/.swarmbar" && install -m 700 /dev/stdin "$HOME/.swarmbar/swarmbar-helper""#
        }
    }
}

/// A request argument. The helper speaks JSON, and a closed set of cases
/// keeps every argument Sendable across the actor boundary where `Any`
/// would not be.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool before the numbers and Int before Double, so `true` and `3`
        // come back as what they were rather than as their widest reading.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
