import Foundation
import SQLite3

/// Reads a live conversation's own database, `conversations/<id>.db`, for
/// the one thing its transcript cannot report: a question waiting on the
/// user right now.
///
/// The transcript writes a line when a step FINISHES, so a prompt sitting
/// on screen has no line at all. It is only in the `steps` table, and the
/// row sampled live while agy asked "Do you approve writing a file
/// containing 'hello'?" looked like this:
///
///     idx  step_type  status  metadata
///     3    15         3       (the planner response, already written out)
///     4    138        9       ask_question, {"questions":[...]}
///
/// Two things there are worth stating plainly, because both are the
/// opposite of a reasonable guess.
///
/// The `permissions` blob column is NOT how a prompt is recorded. It was
/// NULL on the pending step, as it has been on every step ever sampled.
/// It looked like the obvious place and it is not the place.
///
/// And the status is what marks a prompt as live: every completed step
/// says 3, and the pending one said 9. Since 3 is the only value ever seen
/// on a settled step, this treats "not 3" as unsettled rather than
/// ascribing a meaning to 9 it has not earned from one sample.
enum AntigravityConversation {
    /// The only status value ever observed on a settled step.
    nonisolated static let doneStatus: Int64 = 3

    /// A step that has not settled. Two very different things arrive here.
    ///
    /// One is agy's `ask_question` tool, whose arguments carry the question
    /// and its options, so the database alone proves a person is being
    /// asked something.
    ///
    /// The other is an ordinary tool call held at a permission gate, and
    /// the database says NOTHING about that. Sampled live while agy waited
    /// on "Allow creation of this file?", the row was a plain
    /// `write_to_file` call with an unsettled status: no permissions blob,
    /// no task details, nothing to separate it from the same tool merely
    /// running. Only the terminal knows, which is why the caller
    /// corroborates this kind against the screen.
    struct Pending: Sendable, Equatable {
        /// Present only for `ask_question`.
        let question: String?
        let options: [String]
        /// What the agent wants to do, from the tool call's own summary.
        let summary: String

        /// Approve and deny get the orange approval row with its own
        /// buttons; anything else is a question the user answers in words,
        /// which is the blue waiting row. A tool that asks "which of these
        /// three files did you mean" must not be presented as if a wrong
        /// tap could approve a command.
        var isApproval: Bool {
            let lowered = Set(options.map { $0.lowercased() })
            return lowered.contains("approve") && lowered.contains("deny")
        }

        /// What the row shows.
        var label: String { question ?? summary }
    }

    nonisolated static func conversationPath(home: URL, conversationID: String) -> URL {
        home
            .appendingPathComponent("conversations")
            .appendingPathComponent(conversationID + ".db")
    }

    /// The newest unsettled step, or nil when every step has settled. Nil
    /// is also what an unreadable database gives, which is correct: no
    /// evidence of a prompt must never become a prompt.
    nonisolated static func pending(dbPath: String) -> Pending? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        return SQLiteSnapshot.read(dbPath: dbPath) { db -> Pending?? in
            let sql = """
                SELECT metadata FROM steps
                WHERE status <> \(doneStatus)
                ORDER BY idx DESC LIMIT 1
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                // Distinct from "no pending step": the outer optional stays
                // nil so SQLiteSnapshot retries against a copy.
                return nil
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0)
            else { return .some(nil) }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let blob = Data(bytes: bytes, count: count)
            return .some(pending(inMetadata: blob))
        } ?? nil
    }

    /// The metadata column is a protobuf, but the tool call's arguments sit
    /// inside it as a plain JSON string, so the document can be lifted out
    /// whole rather than decoding a schema SwarmBar does not have.
    nonisolated static func pending(inMetadata blob: Data) -> Pending? {
        // Invalid protobuf bytes become replacement characters; the ASCII
        // JSON in the middle survives intact.
        pending(inText: String(decoding: blob, as: UTF8.self))
    }

    nonisolated static func pending(inText text: String) -> Pending? {
        // An ask_question call: the question and its options are right
        // there, so no corroboration is needed.
        if let json = embeddedJSONObject(in: text, containingKey: "\"questions\""),
           let questions = json["questions"] as? [[String: Any]],
           let first = questions.first,
           let prompt = first["question"] as? String, !prompt.isEmpty {
            return Pending(
                question: prompt,
                options: (first["options"] as? [String]) ?? [],
                summary: (json["toolSummary"] as? String) ?? prompt
            )
        }
        // Any other tool call. Every argument object carries toolSummary
        // and toolAction, so one of them describes what is being asked of
        // the user, or what is simply running.
        guard let json = embeddedJSONObject(in: text, containingKey: "\"toolSummary\"")
                ?? embeddedJSONObject(in: text, containingKey: "\"toolAction\""),
              let summary = ((json["toolSummary"] as? String)
                ?? (json["toolAction"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty
        else { return nil }
        return Pending(question: nil, options: [], summary: summary)
    }

    /// Finds the JSON object that opens immediately before `key` and
    /// returns it parsed. Brace counting has to respect strings, since the
    /// questions themselves contain braces and quotes.
    nonisolated static func embeddedJSONObject(
        in text: String, containingKey key: String
    ) -> [String: Any]? {
        guard let keyRange = text.range(of: key) else { return nil }
        // The object opens at the last `{` at or before the key.
        guard let open = text.range(
            of: "{", options: .backwards, range: text.startIndex..<keyRange.upperBound
        )?.lowerBound else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let slice = text[open...index]
                        guard let data = slice.data(using: .utf8) else { return nil }
                        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
