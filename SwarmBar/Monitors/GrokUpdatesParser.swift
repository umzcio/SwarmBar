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

    /// The command (or title) of the most recent tool_call, used as the
    /// approval row's command preview while a permission prompt is pending.
    nonisolated static func pendingToolCommand(tail: String) -> String? {
        for raw in tail.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let params = line["params"] as? [String: Any]
            else { continue }
            let update = (params["update"] as? [String: Any]) ?? params
            guard (update["sessionUpdate"] as? String) == "tool_call" else { continue }
            let rawInput = update["rawInput"] as? [String: Any]
            if let command = rawInput?["command"] as? String { return firstLine(command) }
            let title = update["title"] as? String ?? "tool"
            if let path = (rawInput?["file_path"] ?? rawInput?["absolute_path"] ?? rawInput?["path"]) as? String {
                return "\(title) \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return title
        }
        return nil
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
