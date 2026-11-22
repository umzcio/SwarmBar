import Foundation

/// Maps the tail of a Codex CLI rollout JSONL to a SessionStatus. Lines are
/// {timestamp, type, payload}: event_msg carries lifecycle events
/// (task_started, task_complete, turn_aborted), response_item carries
/// function_call / custom_tool_call and their output pairs.
///
/// Permission prompts: a call whose input asks for escalated sandbox
/// permissions ("sandbox_permissions":"require_escalated", or the legacy
/// "with_escalated_permissions":true) makes the TUI prompt before running,
/// so a trailing escalated call with no matching output line means the
/// prompt is on screen. The rollout itself records the resolution: approve
/// runs the command and appends its output; deny (esc, ExecApproval
/// decision Abort) appends a rejection output.
enum CodexSessionParser {
    static let staleAfter: TimeInterval = 30 * 60

    static func parseDetails(tail: String, now: Date = .now, reviewer: String? = nil) -> ParsedStatus? {
        if let pending = pendingRequest(tail: tail, reviewer: reviewer) {
            return ParsedStatus(status: .waitingApproval(command: pending.prompt),
                cwd: nil, attentionEventID: "call:\(pending.id)")
        }
        for raw in tail.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = line["type"] as? String,
                  let payload = line["payload"] as? [String: Any]
            else { continue }
            let age = (line["timestamp"] as? String)
                .flatMap { ClaudeSessionParser.date($0) }
                .map { now.timeIntervalSince($0) }
            let stale = (age ?? 0) > staleAfter

            func result(_ status: SessionStatus) -> ParsedStatus {
                ParsedStatus(status: status, cwd: nil,
                    attentionEventID: status.needsAttention
                        ? "turn:" + ((payload["turn_id"] as? String)
                            ?? StableID.uuid(for: String(raw)).uuidString)
                        : nil)
            }

            switch type {
            case "event_msg":
                switch payload["type"] as? String {
                case "task_complete":
                    guard let message = payload["last_agent_message"] as? String else {
                        return result(.done(summary: "Task complete"))
                    }
                    let status = SessionStatus.finishedTurn(fullText: message, preview: String(message.prefix(90)))
                    return result(stale && status.needsAttention ? .idle : status)
                case "turn_aborted":
                    return result(.idle)
                case "task_started", "user_message":
                    return result(stale ? .idle : .working(activity: "Working…"))
                default:
                    continue
                }
            case "response_item":
                switch payload["type"] as? String {
                case "function_call", "custom_tool_call":
                    let name = payload["name"] as? String ?? "tool"
                    return result(stale ? .idle : .runningTool(activity: "Running \(name)"))
                case "function_call_output", "custom_tool_call_output":
                    return result(stale ? .idle : .working(activity: "Working through tool results…"))
                default:
                    continue
                }
            default:
                continue
            }
        }
        return nil
    }

    static func parse(tail: String, now: Date = .now) -> SessionStatus? {
        parseDetails(tail: tail, now: now)?.status
    }

    /// The command of the newest escalated call that has no output line
    /// yet, meaning its permission prompt is on screen. Answered calls end
    /// the search: everything older is settled.
    static func pendingApproval(tail: String) -> ApprovalPrompt? {
        pendingRequest(tail: tail)?.prompt
    }

    /// The reviewer the newest turn_context in this text names, if any.
    /// Codex writes one per turn, with `approvals_reviewer` set by
    /// /permissions: `user` asks the person, `auto_review` has Codex's own
    /// reviewer approve or reject every escalation without asking anyone.
    static func reviewer(inTurnContext raw: Substring) -> String? {
        guard let data = raw.data(using: .utf8),
              let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              line["type"] as? String == "turn_context",
              let payload = line["payload"] as? [String: Any]
        else { return nil }
        return payload["approvals_reviewer"] as? String
    }

    /// `reviewer` is what the newest turn_context names when the tail
    /// holds none; a turn_context in the tail is newer and wins. Under
    /// `auto_review` an unanswered escalation is waiting on Codex's own
    /// reviewer, which settles it in seconds and never asks the person
    /// (a rejection goes back to the model), so it is no prompt. Any other
    /// or unknown reviewer is treated as the person, as before.
    ///
    /// Every escalation still unanswered in the current turn is a request,
    /// not just the newest call. One response can carry several calls, all
    /// written before the first is answered, and Codex prompts for them in
    /// order, so a row naming the newest put Approve beside a command other
    /// than the one the `y` answered. With more than one escalation
    /// waiting, the row says it cannot tell which is on screen. A call left
    /// unanswered by an earlier turn (interrupted) is over, so each
    /// turn_context or task_started starts the count again.
    private static func pendingRequest(tail: String, reviewer: String? = nil) -> (prompt: ApprovalPrompt, id: String)? {
        var answered = Set<String>()
        var lines: [[String: Any]] = []
        var reviewer = reviewer
        for raw in tail.split(separator: "\n") {
            if raw.contains("\"turn_context\""), let named = Self.reviewer(inTurnContext: raw) {
                reviewer = named
                lines.removeAll()
                continue
            }
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = line["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }
            switch line["type"] as? String {
            case "turn_context":
                lines.removeAll()
            case "event_msg" where type == "task_started":
                lines.removeAll()
            case "response_item":
                if type.hasSuffix("_call_output"), let callId = payload["call_id"] as? String {
                    answered.insert(callId)
                } else if type == "custom_tool_call" || type == "function_call" {
                    lines.append(payload)
                }
            default:
                break
            }
        }
        guard reviewer != "auto_review" else { return nil }
        let waiting: [(prompt: ApprovalPrompt, id: String)] = lines.compactMap { call in
            guard let callId = call["call_id"] as? String, !answered.contains(callId),
                  let prompt = request(in: call)
            else { return nil }
            return (prompt, callId)
        }
        guard let newest = waiting.last else { return nil }
        guard waiting.count == 1 else {
            return (.unreadable(
                "Codex has more than one command waiting, and SwarmBar cannot tell which one it is asking about. Review it in the terminal."),
                newest.id)
        }
        return newest
    }

    /// What one unanswered call asks for, or nil when it asks for nothing:
    /// a sandboxed call runs without a prompt.
    private static func request(in latest: [String: Any]) -> ApprovalPrompt? {
        let input = (latest["input"] as? String) ?? (latest["arguments"] as? String) ?? ""

        // The call's arguments, read as data. A function_call's arguments
        // are JSON. A custom_tool_call ("code mode") is a JavaScript
        // program, and only the one shape whose single exec_command call
        // takes a literal object is read: anywhere else the command that
        // runs can differ from any literal in the source (a comment, an
        // earlier call, a variable), so no literal is shown as if it were.
        let isFunctionCall = latest["type"] as? String == "function_call"
        let arguments = isFunctionCall
            ? StrictJSONObject.parse(in: input, from: input.startIndex)
                .flatMap { parsed in
                    input.unicodeScalars[parsed.end...].allSatisfy(\.properties.isWhitespace)
                        ? parsed.object : nil
                }
            : codeModeArguments(input)
        guard let arguments else {
            // Unreadable, but it may still be a prompt. Say so rather than
            // either inventing a command or hiding a prompt that is there.
            guard mentionsEscalation(input) else { return nil }
            return .unreadable(
                "SwarmBar cannot read the exact command Codex is asking to run. Review it in the terminal.")
        }
        guard isEscalated(arguments) else { return nil }
        // Code mode is only ever read as its one exec_command call.
        let tool = isFunctionCall ? latest["name"] as? String : "exec_command"
        guard let tool, let command = command(in: arguments, tool: tool) else {
            return .unreadable(
                "SwarmBar cannot read the exact command Codex is asking to run. Review it in the terminal.")
        }
        let workdir = (arguments["workdir"] as? String).map { "\nworkdir: \($0)" } ?? ""
        return ApprovalPrompt(command + workdir)
    }

    private static func mentionsEscalation(_ input: String) -> Bool {
        input.contains("require_escalated") || input.contains("with_escalated_permissions")
    }

    private static func isEscalated(_ arguments: [String: Any]) -> Bool {
        arguments["sandbox_permissions"] as? String == "require_escalated"
            || arguments["with_escalated_permissions"] as? Bool == true
    }

    /// The command the named tool runs: exec_command's `cmd`,
    /// shell_command's `command` string, or the legacy shell tool's argv,
    /// whose `bash -lc <script>` form is shown as the script itself.
    ///
    /// Chosen by the tool's name, never by which keys are present. Each
    /// tool ignores the others' fields, so a call to `shell` carrying a
    /// decoy `cmd` beside its real `command` would show the decoy while
    /// Approve ran the command. A call holding both fields, or a tool not
    /// named here, has no command SwarmBar can vouch for.
    private static func command(in arguments: [String: Any], tool: String) -> String? {
        guard (arguments["cmd"] == nil) != (arguments["command"] == nil) else { return nil }
        switch tool {
        case "exec_command":
            return arguments["cmd"] as? String
        case "shell_command":
            return arguments["command"] as? String
        case "shell":
            break
        default:
            return nil
        }
        guard let argv = arguments["command"] as? [String], !argv.isEmpty else { return nil }
        let shells: Set<String> = ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"]
        if argv.count == 3, shells.contains(argv[0]), ["-lc", "-c"].contains(argv[1]) {
            return argv[2]
        }
        return argv.map(displayQuoted).joined(separator: " ")
    }

    /// A word as a shell would need it written. Quoted by scalar through
    /// the shared `shellQuoted`: a quote fused with a combining mark is a
    /// Character that is not "'", so a Character replace left it bare, and
    /// the row then showed one argument as a quote, a `;` and a command.
    private static func displayQuoted(_ word: String) -> String {
        let plain = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return shellQuoted(word)
    }

    /// The arguments of a code-mode program that is exactly one of
    ///
    ///     [const|let|var <name> =] await tools.exec_command({ ... });
    ///     text(<name>.output);
    ///
    ///     text(await tools.exec_command({ ... }));
    ///
    /// with nothing else in it, or nil. The second is what Codex 0.167
    /// writes. The object may use bare keys as Codex does, read by
    /// StrictJSONObject.parseJavaScriptLiteral only where it means what the
    /// JSON shown means. Any other program, including one with a comment,
    /// a second call or a computed argument, is not read.
    static func codeModeArguments(_ program: String) -> [String: Any]? {
        let identifier = "[A-Za-z_$][A-Za-z0-9_$]*"
        let shapes = [
            (head: "^\\s*(?:(?:const|let|var)\\s+\(identifier)\\s*=\\s*)?await\\s+tools\\.exec_command\\(\\s*",
             textWrapped: false),
            (head: "^\\s*text\\(\\s*await\\s+tools\\.exec_command\\(\\s*",
             textWrapped: true),
        ]
        for shape in shapes {
            guard let headRange = program.range(of: shape.head, options: .regularExpression),
                  let parsed = StrictJSONObject.parseJavaScriptLiteral(in: program, from: headRange.upperBound)
            else { continue }
            guard isAcceptedTail(Array(program.unicodeScalars[parsed.end...]), textWrapped: shape.textWrapped)
            else { continue }
            return parsed.object
        }
        return nil
    }

    /// Whether what follows the call's object literal is exactly
    ///
    ///     ) [;] { text(<name>[.<name>]...) [;] }      (the assigned form)
    ///     ) ) [;]                                      (the text-wrapped form)
    ///
    /// with whitespace anywhere a `\s*` stood in the patterns these
    /// replace, and nothing else.
    ///
    /// Scanned by hand, each scalar looked at once. The text is model
    /// written, and the pattern for the first form ended its repeated group
    /// in two whitespace runs that could split the same spaces any number
    /// of ways, so a long run of `text(…)` statements followed by anything
    /// it refused backtracked exponentially, and the Codex monitor (or a
    /// remote host's whole discovery) never finished another pass.
    private static func isAcceptedTail(_ scalars: [Unicode.Scalar], textWrapped: Bool) -> Bool {
        var index = 0
        func skipSpace() {
            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        }
        func eat(_ word: String) -> Bool {
            let expected = Array(word.unicodeScalars)
            guard index + expected.count <= scalars.count,
                  scalars[index..<index + expected.count].elementsEqual(expected)
            else { return false }
            index += expected.count
            return true
        }
        func identifier() -> Bool {
            func isStart(_ s: Unicode.Scalar) -> Bool {
                s.isASCII && (s.properties.isAlphabetic || s == "_" || s == "$")
            }
            guard index < scalars.count, isStart(scalars[index]) else { return false }
            index += 1
            while index < scalars.count, isStart(scalars[index]) || ("0"..."9").contains(scalars[index]) {
                index += 1
            }
            return true
        }
        // `;?` then whitespace, as the patterns had it.
        func optionalSemicolon() {
            _ = eat(";")
            skipSpace()
        }

        skipSpace()
        guard eat(")") else { return false }
        skipSpace()
        if textWrapped {
            guard eat(")") else { return false }
            skipSpace()
            optionalSemicolon()
            return index == scalars.count
        }
        optionalSemicolon()
        while index < scalars.count {
            guard eat("text(") else { return false }
            skipSpace()
            guard identifier() else { return false }
            while eat(".") {
                guard identifier() else { return false }
            }
            skipSpace()
            guard eat(")") else { return false }
            skipSpace()
            optionalSemicolon()
        }
        return true
    }

    /// The first line of a rollout file is session_meta with cwd and id.
    static func meta(head: String) -> (cwd: String?, sessionId: String?) {
        let payload = metaPayload(head: head)
        return (payload?["cwd"] as? String, payload?["session_id"] as? String)
    }

    /// Whether this rollout belongs to a subagent rather than to the
    /// session a person is talking to.
    ///
    /// Codex gives every spawned subagent its own rollout file next to its
    /// parent's, so without this one Codex run fills the popover: of 172
    /// rollouts on the machine where this was found, 147 were subagents.
    ///
    /// Taken from Codex's own `thread_source`, which is `subagent` for a
    /// spawned thread and `user` for a real one. Rollouts written before
    /// multi-agent support have no marker at all, and those are kept: an
    /// absent field means "not known to be a subagent", and treating it as
    /// one would silently hide genuine sessions.
    static func isSubagent(head: String) -> Bool {
        metaPayload(head: head)?["thread_source"] as? String == "subagent"
    }

    private static func metaPayload(head: String) -> [String: Any]? {
        for raw in head.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  line["type"] as? String == "session_meta",
                  let payload = line["payload"] as? [String: Any]
            else { continue }
            return payload
        }
        return nil
    }
}
