import Foundation

/// Maps the tail of a Grok Build session's updates.jsonl to a
/// SessionStatus. Lines are JSON-RPC style envelopes whose
/// params.update.sessionUpdate carries ACP-flavored events:
/// user/agent/thought message chunks, tool_call / tool_call_update, and
/// hook_execution markers (event_name "stop" ends a turn). A trailing
/// ask_user_question tool call is the agent explicitly waiting on the
/// user and surfaces its first question as the prompt.
enum GrokUpdatesParser {
    nonisolated static func parse(tail: String) -> SessionStatus? {
        var sawStop = false
        for raw in tail.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let params = line["params"] as? [String: Any]
            else { continue }
            let update = (params["update"] as? [String: Any]) ?? params
            guard let kind = update["sessionUpdate"] as? String else { continue }

            switch kind {
            case "hook_execution":
                if (update["event_name"] as? String) == "stop" { sawStop = true }

            case "tool_call":
                if sawStop { return .waitingInput(prompt: "") }
                let title = update["title"] as? String ?? "tool"
                if title == "ask_user_question" {
                    return .waitingInput(prompt: question(from: update) ?? "")
                }
                return .runningTool(activity: "Running \(title)")

            case "tool_call_update":
                return sawStop ? .waitingInput(prompt: "") : .working(activity: "Working…")

            case "agent_message_chunk":
                if sawStop {
                    let text = chunkText(update)
                    return .finishedTurn(
                        fullText: text ?? "",
                        preview: text.map(firstLine) ?? ""
                    )
                }
                return .working(activity: "Responding…")

            case "agent_thought_chunk", "user_message_chunk":
                return sawStop ? .waitingInput(prompt: "") : .working(activity: "Thinking…")

            default:
                continue
            }
        }
        return sawStop ? .waitingInput(prompt: "") : nil
    }

    /// The request a pending permission prompt is about, in full, for the
    /// approval row.
    ///
    /// Not simply the newest tool_call: a call made after the gated one
    /// (a read_file queued beside a gated run_command) would put a benign
    /// request beside an Approve that answers the gated one. The call is
    /// the one events.jsonl names: by id where it gives one, otherwise the
    /// only unfinished call of the named tool. With no unique match the
    /// row says so and offers the terminal instead of Approve.
    ///
    /// "The only unfinished call" is a claim about every call the turn has
    /// made, and `tail` may be a suffix of the file. A gated call whose own
    /// record ends before the suffix starts is simply not in it, and a
    /// later call of the same tool would then pass for the only one. So
    /// without an id the text must be shown to hold every call that could
    /// be waiting: either it was read from the file's start (`fromStart`),
    /// or it holds a turn boundary (the stop hook), and then only the calls
    /// after the last boundary are candidates, since a call from a turn
    /// that has ended is not the one a prompt in this turn is about.
    nonisolated static func pendingToolPrompt(
        tail: String, tool: String, callID: String?, fromStart: Bool
    ) -> ApprovalPrompt {
        var calls: [(id: String?, title: String, rawInput: [String: Any]?)] = []
        var finished = Set<String>()
        // How many calls came before the last turn boundary, once one is seen.
        var turnStart: Int?
        for raw in tail.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let params = line["params"] as? [String: Any]
            else { continue }
            let update = (params["update"] as? [String: Any]) ?? params
            let id = update["toolCallId"] as? String
            switch update["sessionUpdate"] as? String {
            case "tool_call":
                calls.append((id, update["title"] as? String ?? "tool",
                              update["rawInput"] as? [String: Any]))
            case "tool_call_update":
                if let id, let status = update["status"] as? String,
                   ["completed", "failed", "cancelled"].contains(status) {
                    finished.insert(id)
                }
            case "hook_execution":
                if (update["event_name"] as? String) == "stop" { turnStart = calls.count }
            default:
                continue
            }
        }
        let candidates: [(id: String?, title: String, rawInput: [String: Any]?)]
        if let callID {
            candidates = calls.filter { $0.id == callID }.suffix(1)
        } else {
            let examined: ArraySlice<(id: String?, title: String, rawInput: [String: Any]?)>
            if fromStart {
                examined = calls[...]
            } else if let turnStart {
                examined = calls[turnStart...]
            } else {
                return .unreadable(
                    "SwarmBar could not read far enough back to tell which \(tool) call Grok is asking about. Review it in the terminal.")
            }
            candidates = examined.filter { call in
                call.title == tool && !(call.id.map(finished.contains) ?? false)
            }
        }
        guard candidates.count == 1, let call = candidates.first else {
            return .unreadable(
                "SwarmBar cannot tell which \(tool) call Grok is asking about. Review it in the terminal.")
        }
        guard var input = call.rawInput else {
            return .unreadable(
                "Grok has not recorded what this \(tool) call would do. Review it in the terminal.")
        }
        // Taken out of the arguments only once it is known to be a string.
        // removeValue runs before the cast, so removing first dropped an
        // argv array or an object from a prompt still offered as exact;
        // anything else stays an argument and is described as JSON.
        if let command = input["command"] as? String {
            input.removeValue(forKey: "command")
            // The whole command, every line of it, with anything else the
            // call carries (its working directory, say) after it.
            let rest = ApprovalPrompt.describeArguments(input)
            return ApprovalPrompt(rest.isEmpty ? command : command + "\n" + rest)
        }
        return ApprovalPrompt(ApprovalPrompt.describe(tool: call.title, arguments: input))
    }

    private nonisolated static func question(from update: [String: Any]) -> String? {
        guard let rawInput = update["rawInput"] as? [String: Any],
              let questions = rawInput["questions"] as? [[String: Any]],
              let first = questions.first?["question"] as? String
        else { return nil }
        return firstLine(first)
    }

    private nonisolated static func chunkText(_ update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any] else { return nil }
        return content["text"] as? String
    }

    private nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 90 ? trimmed : String(trimmed.prefix(90)) + "…"
    }
}
