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
            Self.sshOptions + ["--", alias, "sudo", "-n", Self.rootHelperPath]
        case .ssh(let alias, .loginUser):
            // One string on purpose: ssh hands it to the remote login shell,
            // which is what expands $HOME. Split into separate arguments, the
            // quotes would arrive literally.
            // -I, as the helper's own shebang says for root: nothing beside
            // the script, in the user site or in PYTHON* variables is on its
            // path.
            Self.sshOptions + ["--", alias, #"exec python3 -I "$HOME/.swarmbar/swarmbar-helper""#]
        case .local(_, let script, _):
            [script]
        }
    }

    /// The install push's ssh argv. The `--` precedes the alias in every ssh
    /// argv the app builds, so an alias can never be read as an option.
    static func installArguments(alias: String, watchAs: WatchAs) -> [String] {
        sshOptions + ["--", alias, installCommand(for: watchAs)]
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
    /// there is only ever one channel to authorize. Idempotent: the rename
    /// overwrites, so a redeploy is safe.
    ///
    /// `cat` into a temporary file and a rename, rather than `install` from
    /// /dev/stdin, because BSD install refuses /dev/stdin ("Inappropriate
    /// file type or format") and Darwin hosts are in the fleet. The umask
    /// keeps the file private from its first byte, and the rename means a
    /// helper that is running never sees a half-written copy of itself.
    static func installCommand(for watchAs: WatchAs) -> String {
        switch watchAs {
        case .everyUser:
            "sudo -n sh -c '\(rootInstallScript(directory: (rootHelperPath as NSString).deletingLastPathComponent, owner: 0))'"
        case .loginUser:
            #"mkdir -p "$HOME/.swarmbar" && chmod 700 "$HOME/.swarmbar" && umask 077 && cat > "$HOME/.swarmbar/swarmbar-helper.tmp" && chmod 700 "$HOME/.swarmbar/swarmbar-helper.tmp" && mv -f "$HOME/.swarmbar/swarmbar-helper.tmp" "$HOME/.swarmbar/swarmbar-helper""#
        }
    }
}

extension HelperLaunch {
    /// The root install, as one sh script with no single quote in it, so
    /// it rides inside `sh -c '...'`. Root writes a predictable temporary
    /// name in the directory, so the directory must be one nobody else can
    /// change: owned by `owner` (root, or a test's own user standing in for
    /// it) and writable by neither group nor others, or another user could
    /// put a link where the temporary file goes. A fresh macOS may have no
    /// /usr/local/lib, so it is made, 0755 like the rest of /usr/local.
    /// `ls -ldn` rather than stat, whose flags differ between GNU and BSD.
    static func rootInstallScript(directory: String, owner: Int) -> String {
        let helper = directory + "/" + (rootHelperPath as NSString).lastPathComponent
        return "d=\(directory); "
            + #"if [ ! -e "$d" ]; then (umask 022 && mkdir -p "$d") || exit 1; fi; "#
            + #"set -- $(ls -ldn "$d") || exit 1; "#
            + #"case "$1" in d????w*|d???????w*) echo "swarmbar: $d is writable by another user" >&2; exit 1;; "#
            + #"d*) ;; *) echo "swarmbar: $d is not a directory" >&2; exit 1;; esac; "#
            + #"[ "$3" = \#(owner) ] || { echo "swarmbar: $d is not owned by the right user" >&2; exit 1; }; "#
            + "umask 077; cat > \(helper).tmp && chmod 700 \(helper).tmp && mv -f \(helper).tmp \(helper)"
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
