import Foundation

/// Maps the tail of a Codex CLI rollout JSONL to a SessionStatus. Lines are
/// {timestamp, type, payload}: event_msg carries lifecycle events
/// (task_started, task_complete, turn_aborted), response_item carries
/// function_call / function_call_output pairs.
enum CodexSessionParser {
    static let staleAfter: TimeInterval = 30 * 60

    static func parse(tail: String, now: Date = .now) -> SessionStatus? {
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

            switch type {
            case "event_msg":
                switch payload["type"] as? String {
                case "task_complete":
                    let summary = (payload["last_agent_message"] as? String)
                        .map { String($0.prefix(90)) } ?? "Task complete"
                    return .done(summary: summary)
                case "turn_aborted":
                    return .idle
                case "task_started", "user_message":
                    return stale ? .idle : .working(activity: "Working…")
                default:
                    continue
                }
            case "response_item":
                switch payload["type"] as? String {
                case "function_call":
                    let name = payload["name"] as? String ?? "tool"
                    return stale ? .idle : .runningTool(activity: "Running \(name)")
                case "function_call_output":
                    return stale ? .idle : .working(activity: "Working through tool results…")
                default:
                    continue
                }
            default:
                continue
            }
        }
        return nil
    }

    /// The first line of a rollout file is session_meta with cwd and id.
    static func meta(head: String) -> (cwd: String?, sessionId: String?) {
        for raw in head.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  line["type"] as? String == "session_meta",
                  let payload = line["payload"] as? [String: Any]
            else { continue }
            return (payload["cwd"] as? String, payload["session_id"] as? String)
        }
        return (nil, nil)
    }
}
