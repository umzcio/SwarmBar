import Foundation

/// Maps the tail of a Kimi Code wire.jsonl to a SessionStatus. Events are
/// either bare (turn.prompt, llm.request, usage.record, turn.cancel,
/// permission.record_approval_result) or context.append_loop_event
/// envelopes whose event.type is step.begin / step.end / content.part
/// (think or text) / tool.call / tool.result.
///
/// Kimi buffers a step's events and flushes them together when the step
/// resolves, so mid-step state (including pending approval prompts) never
/// reaches disk in realtime; the trailing events describe the last settled
/// state, which is still a big step up from recency guessing.
enum KimiWireParser {
    nonisolated static func parse(tail: String) -> SessionStatus? {
        let lines = tail.split(separator: "\n").compactMap(decode)
        let lastText = lines.reversed().lazy.compactMap(text(from:)).first
        let finished = SessionStatus.finishedTurn(
            fullText: lastText ?? "",
            preview: (lastText).map(firstLine) ?? ""
        )

        for line in lines.reversed() {
            switch line["type"] as? String {
            case "turn.cancel":
                return .idle
            case "turn.prompt", "llm.request":
                return .working(activity: "Thinking…")
            case "usage.record":
                return finished
            case "context.append_loop_event":
                guard let event = line["event"] as? [String: Any],
                      let kind = event["type"] as? String
                else { continue }
                switch kind {
                case "step.begin":
                    return .working(activity: "Working…")
                case "step.end":
                    return finished
                case "content.part":
                    let part = event["part"] as? [String: Any]
                    if let text = part?["text"] as? String {
                        return .finishedTurn(fullText: text, preview: firstLine(text))
                    }
                    return .working(activity: "Thinking…")
                case "tool.call":
                    let display = event["display"] as? [String: Any]
                    let command = (display?["command"] as? String)
                        ?? (event["name"] as? String)
                        ?? "tool"
                    return .runningTool(activity: "Running \(firstLine(command))")
                case "tool.result":
                    return .working(activity: "Working through tool results…")
                default:
                    continue
                }
            default:
                // metadata, config.update, tools snapshots, approval
                // records: history, not state.
                continue
            }
        }
        return nil
    }

    private nonisolated static func decode(_ raw: Substring) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private nonisolated static func text(from line: [String: Any]) -> String? {
        guard line["type"] as? String == "context.append_loop_event",
              let event = line["event"] as? [String: Any],
              event["type"] as? String == "content.part",
              let part = event["part"] as? [String: Any]
        else { return nil }
        return part["text"] as? String
    }

    private nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 90 ? trimmed : String(trimmed.prefix(90)) + "…"
    }
}
