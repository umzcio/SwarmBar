import Foundation

/// The two ways a person sets a host up when SwarmBar can't do it over
/// ssh itself: a one-line command they run there, or a prompt they paste
/// into an agent already running there.
enum SetupCommand {
    static let releases = "https://github.com/umzcio/SwarmBar/releases/download"

    static func helperURL(version: String) -> String {
        "\(releases)/v\(version)/swarmbar-helper.py"
    }

    /// Shown whenever a plan sets up the narrow sudo rule. The rule lets
    /// that login run root's helper, and the helper answers root's agents
    /// and writes root's configs, so the rule is root for that account.
    static func everyUserWarning(user: String) -> String {
        "This lets \(user) act as root through SwarmBar's helper. Only set this up for an account you'd trust with root."
    }

    /// One line: download the helper this version released into a fresh
    /// private directory, check its sha256, and run its `apply` on the
    /// plan. Never a fixed /tmp path, where another local user could swap
    /// the file between the check and sudo. The directory goes either way.
    static func command(plan: SetupPlan, system: String, version: String, helperSHA256: String) -> String {
        let check = system == "Darwin" ? "shasum -a 256 -c -" : "sha256sum -c -"
        let sudo = plan.watchAs == .everyUser ? "sudo " : ""
        let blob = blob(operations(plan: plan, helperSHA256: helperSHA256))
        return #"d=$(mktemp -d) && curl -fsSL \#(helperURL(version: version)) -o "$d/swarmbar-helper.py" && "#
            + #"echo "\#(helperSHA256)  $d/swarmbar-helper.py" | \#(check) && "#
            + #"\#(sudo)python3 -B "$d/swarmbar-helper.py" apply '\#(blob)'; rm -rf "$d""#
    }

    /// The helper's operations, in the order `apply` runs them: the helper
    /// and the sudo rule that names it first, then each change that is
    /// sent. A hand edit is the person's, never the command's.
    static func operations(plan: SetupPlan, helperSHA256: String) -> [JSONValue] {
        var operations: [JSONValue] = []
        if plan.installHelper {
            operations.append(.object([
                "op": .string("install_helper"), "dest": .string(plan.helperDestination),
                "expect_sha256": .string(helperSHA256),
            ]))
        }
        if let user = plan.sudoersUser {
            operations.append(.object(["op": .string("sudoers"), "user": .string(user)]))
        }
        for change in plan.changes {
            switch change.action {
            case .write(let text, let mode):
                operations.append(.object([
                    "op": .string("write_file"), "path": .string(change.path),
                    "content_b64": .string(Data(text.utf8).base64EncodedString()),
                    "expect_sha256": .string(change.expectSHA256), "mode": .int(mode),
                ]))
            case .remove:
                operations.append(.object(["op": .string("remove_file"), "path": .string(change.path)]))
            case .byHand, .skipped:
                break
            }
        }
        return operations
    }

    /// base64 of the deflated JSON. Foundation's `.zlib` is raw deflate,
    /// which `apply` reads as well as zlib's own framing. An empty blob,
    /// if compression ever failed, makes `apply` refuse rather than guess.
    static func blob(_ operations: [JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let json = try? encoder.encode(JSONValue.array(operations)),
              let packed = try? (json as NSData).compressed(using: .zlib)
        else { return "" }
        return (packed as Data).base64EncodedString()
    }

    /// Plain text for an agent on the host: exactly these changes and
    /// nothing else, each guarded by the hash it must have first, with a
    /// one-time backup, and a check to finish. The sudo rule is never in
    /// it: it needs the user's password, which an agent must not be given.
    static func prompt(plan: SetupPlan, hostName: String) -> String {
        var out: [String] = []
        out.append("Set up SwarmBar on \(hostName). Make exactly the changes below, in order, and nothing else.")
        out.append("""
            Before you change a file, check its sha256 with `sha256sum <path>` on Linux or \
            `shasum -a 256 <path>` on macOS. If a hash differs from the one given here, or a file exists \
            that must not exist yet, stop and report it. Do not change anything to make it match.
            """)
        if let user = plan.sudoersUser {
            out.append("SwarmBar's helper and its sudo rule are not part of this. The sudo rule needs \(user)'s password, so set them up with the setup command instead.")
        } else if plan.installHelper {
            out.append("SwarmBar's helper is not part of this. Install it with the setup command instead.")
        }

        let sent = plan.changes.filter(\.isSent)
        for (number, change) in sent.enumerated() {
            var step = ["\(number + 1). \(change.path)", "\(change.description)."]
            switch change.action {
            case .write(let text, let mode):
                if change.expectSHA256 == SetupPlanner.absent {
                    step.append("It must not exist yet. Create it with mode \(octal(mode)), and any folder it needs with mode 0700, owned by the user whose home it is in.")
                } else {
                    step.append("It must have sha256 \(change.expectSHA256) before you change it.")
                    step.append("If \(change.path).backup-swarmbar does not exist, copy \(change.path) to \(change.path).backup-swarmbar first, keeping its permissions.")
                }
                step.append(change.expectSHA256 == SetupPlanner.absent
                    ? "Its whole contents must be exactly this:"
                    : "Replace its whole contents with exactly this:")
                let fence = fence(for: text)
                step.append(fence + "\n" + (text.hasSuffix("\n") ? text : text + "\n") + fence)
            case .remove:
                step.append("Delete it if it is there.")
            case .byHand, .skipped:
                break
            }
            out.append(step.joined(separator: "\n"))
        }

        let byHand = plan.changes.filter { $0.action == .byHand }
        if !byHand.isEmpty {
            out.append("These need a person, so leave them alone and mention them when you report:\n"
                + byHand.map { "- \($0.description)" }.joined(separator: "\n"))
        }

        if !sent.isEmpty {
            let lines = sent.map { change -> String in
                let expect: String
                switch change.action {
                case .write(let text, _): expect = text.contains("swarmbar-remote") ? "1 or more" : "0"
                default: expect = "No such file"
                }
                return "grep -c swarmbar-remote \(shellWord(change.path))  # expect \(expect)"
            }
            out.append("When you are done, run this check and report its output:\n```\n"
                + lines.joined(separator: "\n") + "\n```")
        }
        out.append("If any hash differed along the way, stop and report it rather than finishing.")
        return out.joined(separator: "\n\n") + "\n"
    }

    // MARK: Pieces

    private static func octal(_ mode: Int) -> String {
        "0" + String(mode, radix: 8)
    }

    /// A fence longer than any run of backticks in the text, so the block
    /// cannot end early whatever the file holds.
    private static func fence(for text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// The path as one shell word, quoted only when it needs to be.
    private static func shellWord(_ path: String) -> String {
        let plain = path.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/._-+".unicodeScalars.contains($0))
        }
        return plain && !path.isEmpty ? path : shellQuoted(path)
    }
}
