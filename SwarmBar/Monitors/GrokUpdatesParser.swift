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
    nonisolated static func pendingToolPrompt(
        tail: String, tool: String, callID: String?
    ) -> ApprovalPrompt {
        var calls: [(id: String?, title: String, rawInput: [String: Any]?)] = []
        var finished = Set<String>()
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
            default:
                continue
            }
        }
        let candidates: [(id: String?, title: String, rawInput: [String: Any]?)]
        if let callID {
            candidates = calls.filter { $0.id == callID }.suffix(1)
        } else {
            candidates = calls.filter { call in
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
        if let command = input.removeValue(forKey: "command") as? String {
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
