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

    static func parseDetails(tail: String, now: Date = .now) -> ParsedStatus? {
        if let pending = pendingRequest(tail: tail) {
            return ParsedStatus(status: .waitingApproval(command: pending.command),
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
    static func pendingApproval(tail: String) -> String? {
        pendingRequest(tail: tail)?.command
    }

    private static func pendingRequest(tail: String) -> (command: String, id: String)? {
        var answered = Set<String>()
        var lines: [[String: Any]] = []
        for raw in tail.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  line["type"] as? String == "response_item",
                  let payload = line["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }
            if type.hasSuffix("_call_output"), let callId = payload["call_id"] as? String {
                answered.insert(callId)
            } else if type == "custom_tool_call" || type == "function_call" {
                lines.append(payload)
            }
        }
        guard let latest = lines.last else { return nil }
        let input = (latest["input"] as? String) ?? (latest["arguments"] as? String) ?? ""
        guard let callId = latest["call_id"] as? String,
              !answered.contains(callId),
              input.contains("require_escalated") || input.contains("\"with_escalated_permissions\":true")
        else { return nil }
        return (field("cmd", in: input) ?? field("justification", in: input) ?? "escalated command", callId)
    }

    /// Pulls a string field out of the call input, which is JS source for
    /// custom_tool_call ("code mode") and plain JSON for function_call.
    private static func field(_ name: String, in input: String) -> String? {
        guard let range = input.range(of: "\"\(name)\":\"") else { return nil }
        var value = ""
        var escaped = false
        for character in input[range.upperBound...] {
            if escaped {
                switch character {
                case "n": value.append(" ")
                case "t": value.append(" ")
                default: value.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                value.append(character)
            }
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 90 ? trimmed : String(trimmed.prefix(90)) + "…"
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
