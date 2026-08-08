import Foundation

/// Antigravity writes one JSON line per completed step to
/// brain/<conversation-id>/.system_generated/logs/transcript.jsonl.
///
/// This is the friendliest transcript of any tool SwarmBar watches. Where
/// the conversation database stores step type and status as bare integers
/// beside protobuf blobs, the transcript spells the same fields as names:
/// `source` (USER_EXPLICIT, MODEL, SYSTEM), `type` (USER_INPUT,
/// PLANNER_RESPONSE, VIEW_FILE, LIST_DIRECTORY, EPHEMERAL_MESSAGE,
/// CHECKPOINT, CONVERSATION_HISTORY), `status`, `created_at`, `content`,
/// and `tool_calls`. Nothing here needs the database.
///
/// Two shapes are worth knowing before reading the mapping below.
///
/// A line is written when its step FINISHES, so a session mid-turn simply
/// stops appending. That is what makes the last line meaningful: a turn
/// that is over ends with a PLANNER_RESPONSE carrying text and no tool
/// calls, and anything else trailing the file means the agent still owes
/// the user a reply.
///
/// Lines are not in step order. Steps that complete together are appended
/// as each lands, so `step_index` 5 can follow 6. The index is the
/// authority (it is the database's primary key), so the newest step is the
/// highest index, never the last line.
enum AntigravityTranscript {
    struct Step: Sendable, Equatable {
        let index: Int
        let source: String
        let type: String
        /// Parsed and carried, deliberately not mapped. Every step sampled
        /// so far says DONE, so the rest of the vocabulary is unknown and
        /// guessing at it would invent states. See `status(for:)`.
        let status: String
        let createdAt: Date?
        let content: String
        /// `toolAction` from each call, already unwrapped: the values in
        /// `args` are JSON strings holding JSON, so the raw field reads
        /// "\"Viewing server.js\"" with the quotes inside it.
        let toolActions: [String]
    }

    nonisolated static func steps(in text: String) -> [Step] {
        text.split(separator: "\n")
            .compactMap { step(fromLine: String($0)) }
            .sorted { $0.index < $1.index }
    }

    nonisolated static func step(fromLine line: String) -> Step? {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let index = json["step_index"] as? Int,
              let type = json["type"] as? String
        else { return nil }
        return Step(
            index: index,
            source: json["source"] as? String ?? "",
            type: type,
            status: json["status"] as? String ?? "",
            createdAt: (json["created_at"] as? String).flatMap(ClaudeSessionParser.date),
            content: json["content"] as? String ?? "",
            toolActions: toolActions(json["tool_calls"])
        )
    }

    nonisolated static func toolActions(_ raw: Any?) -> [String] {
        guard let calls = raw as? [[String: Any]] else { return [] }
        return calls.compactMap { call in
            let args = call["args"] as? [String: Any]
            if let action = (args?["toolAction"] as? String).map(unwrapJSONString),
               !action.isEmpty {
                return action
            }
            // Falls back to the tool's own name, which is always present.
            return (call["name"] as? String).map(humanize)
        }
    }

    /// Every value in `args` is a JSON document encoded as a string, so a
    /// plain string arrives wrapped in its own quotes.
    nonisolated static func unwrapJSONString(_ raw: String) -> String {
        guard raw.hasPrefix("\""),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) as? String
        else { return raw }
        return decoded
    }

    /// LIST_DIRECTORY -> "List directory". The type names are the only
    /// description a tool-result step carries.
    nonisolated static func humanize(_ type: String) -> String {
        let words = type.split(separator: "_").map { $0.lowercased() }
        guard let first = words.first else { return type }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }

    /// The user's own words, dug out of the USER_INPUT envelope. The step's
    /// content wraps the prompt in <USER_REQUEST> and follows it with
    /// metadata blocks the user never typed.
    nonisolated static func userRequest(in content: String) -> String {
        guard let open = content.range(of: "<USER_REQUEST>"),
              let close = content.range(of: "</USER_REQUEST>")
        else { return content.trimmingCharacters(in: .whitespacesAndNewlines) }
        return content[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when the transcript says nothing usable, which leaves the caller
    /// free to fall back rather than inventing a state.
    ///
    /// SYSTEM steps are skipped: EPHEMERAL_MESSAGE, CHECKPOINT and
    /// CONVERSATION_HISTORY are scaffolding the runtime writes around a
    /// turn, and one of them is almost always the newest line even when the
    /// agent is plainly working.
    nonisolated static func status(for steps: [Step]) -> SessionStatus? {
        guard let step = steps.last(where: { $0.source != "SYSTEM" }) else { return nil }
        switch step.type {
        case "USER_INPUT":
            // The user has spoken and no model step has landed yet.
            let request = userRequest(in: step.content)
            return .working(activity: request.isEmpty ? "Working…" : preview(request))
        case "PLANNER_RESPONSE":
            if let action = step.toolActions.first {
                return .runningTool(activity: action)
            }
            // A planner response with no tool calls is the end of the turn.
            return SessionStatus.finishedTurn(
                fullText: step.content, preview: preview(step.content))
        default:
            // A tool result: the model is mid-turn and the next planner
            // step has not been written yet.
            return .working(activity: humanize(step.type))
        }
    }

    nonisolated static func preview(_ text: String, limit: Int = 120) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}
