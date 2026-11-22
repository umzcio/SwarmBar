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

    /// Past this a step's metadata is not read at all: the step counts as a
    /// call SwarmBar cannot read, and the row offers the terminal. A file
    /// write carries the file in its arguments, so this is generous, but a
    /// remote host can ship far more than any real step holds.
    nonisolated static let maxMetadataBytes = 8 << 20

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
        /// The model writes it, so it is context, never the request.
        let summary: String
        /// What Approve would allow: the question itself for
        /// `ask_question`, and for a gated tool call its name and real
        /// arguments, or a plain statement that they could not be read.
        let prompt: ApprovalPrompt

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
                ORDER BY idx DESC
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                // Distinct from "no pending step": the outer optional stays
                // nil so SQLiteSnapshot retries against a copy.
                return nil
            }
            defer { sqlite3_finalize(statement) }
            var blobs: [Data] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else {
                    blobs.append(Data())
                    continue
                }
                blobs.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            }
            return .some(pending(inMetadata: blobs))
        } ?? nil
    }

    /// What a run of unsettled steps, newest first, says is waiting.
    ///
    /// The newest one alone once decided, and agy can hold more than one
    /// call unsettled at a time: one planner response carries several tool
    /// calls. The gate on screen then belongs to whichever call agy is
    /// asking about, which nothing in the database names, so a row showing
    /// the newest call could put Approve on a different one. When more than
    /// one unsettled step carries a tool call, the row says it cannot tell
    /// which call is being asked about and offers the terminal.
    nonisolated static func pending(inMetadata blobs: [Data]) -> Pending? {
        let calls = blobs.compactMap { pending(inMetadata: $0) }
        guard let newest = calls.first else { return nil }
        guard calls.count == 1 else {
            return Pending(
                question: nil, options: [], summary: newest.summary,
                prompt: .unreadable(
                    "Antigravity has more than one call waiting, and SwarmBar cannot tell which one it is asking about. Review it in the terminal.",
                    context: newest.summary))
        }
        return newest
    }

    /// The metadata column is a protobuf, but the tool call's arguments sit
    /// inside it as a plain JSON string, so the document can be lifted out
    /// whole rather than decoding a schema SwarmBar does not have.
    ///
    /// A blob past `maxMetadataBytes` is not read: it may be a call, and
    /// one SwarmBar cannot read, so it counts as one and offers the
    /// terminal.
    nonisolated static func pending(inMetadata blob: Data) -> Pending? {
        guard blob.count <= maxMetadataBytes else { return unreadableCall(summary: nil) }
        // Invalid protobuf bytes become replacement characters; the ASCII
        // JSON in the middle survives intact.
        return pending(inText: String(decoding: blob, as: UTF8.self))
    }

    /// A step that may hold a tool call SwarmBar cannot read. It counts as
    /// a call waiting, so it can never be the one beside a call that can be
    /// read, and it is never offered for approval.
    private nonisolated static func unreadableCall(summary: String?) -> Pending {
        let summary = summary ?? "Tool call"
        return Pending(
            question: nil, options: [], summary: summary,
            prompt: .unreadable(
                "SwarmBar cannot read what Antigravity is asking to do. Review it in the terminal.",
                context: summary))
    }

    nonisolated static func pending(inText text: String) -> Pending? {
        guard text.utf8.count <= maxMetadataBytes else { return unreadableCall(summary: nil) }
        // An ask_question call: the question and its options are right
        // there, so no corroboration is needed. Only when the step's one
        // framed call NAMES that tool: going by a `questions` key alone let
        // a model add one to a gated run_command's arguments, and the row
        // then showed a harmless question while Approve answered the gate
        // for the command.
        let calls = framedCalls(in: text)
        if let calls, calls.count == 1, calls[0].tool == "ask_question",
           let questions = calls[0].arguments["questions"] as? [[String: Any]],
           let first = questions.first,
           let prompt = first["question"] as? String, !prompt.isEmpty {
            let json = calls[0].arguments
            return Pending(
                question: prompt,
                options: (first["options"] as? [String]) ?? [],
                summary: (json["toolSummary"] as? String) ?? prompt,
                prompt: ApprovalPrompt(prompt)
            )
        }
        // Any other tool call. The summary and action are context only, so
        // they come from the framed call's own object when there is one and
        // are looked for leniently otherwise.
        let framed = calls?.count == 1 ? calls?.first : nil
        let summaryObject = framed?.arguments
            ?? outermostObject(in: text).flatMap { json in
                json["toolSummary"] != nil || json["toolAction"] != nil ? json : nil
            }
            ?? embeddedJSONObject(in: text, containingKey: "\"toolSummary\"")
            ?? embeddedJSONObject(in: text, containingKey: "\"toolAction\"")
        let written = ((summaryObject?["toolSummary"] as? String)
            ?? (summaryObject?["toolAction"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (written?.isEmpty == false ? written : nil)
            ?? framed?.tool.map(AntigravityTranscript.humanize)
        guard let calls else {
            // A frame that would not parse: whatever it is, it cannot be
            // ruled out as a call.
            return unreadableCall(summary: summary)
        }
        if calls.count > 1 {
            return unreadableCall(summary: summary)
        }
        // A framed call counts whether or not the model wrote summary keys
        // into it. With no frame, only an argument object carrying them
        // says a call is here at all.
        guard let summary else { return nil }
        return Pending(
            question: nil, options: [], summary: summary,
            prompt: gatedPrompt(in: text, summary: summary, calls: calls))
    }

    /// The gated call's own arguments, for the approval row. The summary
    /// beside them is the model's description of the call, and a model
    /// following injected text can describe `curl … | sh` as "Listing
    /// files", so it is only ever shown as context.
    ///
    /// The call is read from the protobuf frame that names the tool and
    /// carries its arguments, `<length><tool name>{…}` (sampled live as
    /// `\u{0d}write_to_file{"CodeContent":…}`). Exactly one such frame
    /// must be present: a second one, say inside other text the step
    /// carries, makes the call ambiguous, and an ambiguous call is not
    /// offered for approval.
    ///
    /// Found by structure, never by the model-written summary keys: those
    /// can be left off the call and put on an object nested in its
    /// arguments beside decoy values, and the nested object was once shown
    /// as the request while Approve allowed the real one.
    nonisolated static func gatedPrompt(in text: String, summary: String) -> ApprovalPrompt {
        gatedPrompt(in: text, summary: summary, calls: framedCalls(in: text))
    }

    private nonisolated static func gatedPrompt(
        in text: String, summary: String, calls: [Frame]?
    ) -> ApprovalPrompt {
        let unreadable = ApprovalPrompt.unreadable(
            "SwarmBar cannot read what Antigravity is asking to do. Review it in the terminal.",
            context: summary)
        guard let calls else { return unreadable }
        let call: Frame
        if calls.count == 1 {
            call = calls[0]
        } else if calls.isEmpty,
                  occurrences(of: "\"toolSummary\"", in: text) <= 1,
                  occurrences(of: "\"toolAction\"", in: text) <= 1,
                  let json = outermostObject(in: text),
                  json["toolSummary"] != nil || json["toolAction"] != nil {
            // No frame (a tool name the frame reader cannot see), but one
            // outermost argument object, carrying the keys itself.
            call = (nil, json)
        } else {
            return unreadable
        }
        var arguments = call.arguments
        arguments.removeValue(forKey: "toolSummary")
        arguments.removeValue(forKey: "toolAction")
        guard !arguments.isEmpty else { return unreadable }
        return ApprovalPrompt(ApprovalPrompt.describe(
            tool: call.tool ?? "Tool call", arguments: arguments))
    }

    typealias Frame = (tool: String?, arguments: [String: Any])

    /// Every `<length><name>{json}` frame, which is how a tool call's
    /// arguments sit in the step's metadata, read whether or not the model
    /// wrote summary keys into it. Nil when the text cannot be read: a
    /// candidate frame that does not parse (a repeated key, say), since
    /// what lies inside it can then be anything, and an object nested in
    /// it must never stand in for the call.
    ///
    /// One pass. A parsed frame is skipped whole, so nothing nested inside
    /// it is ever taken for a frame of its own; the first frame that does
    /// not parse ends the scan; and a second frame ends it too, since two
    /// already make the call ambiguous. Each candidate used to restart a
    /// full parse to the end of the text and the scan then moved on by one
    /// scalar, so a few megabytes of unclosed frames never finished.
    nonisolated static func framedCalls(in text: String) -> [Frame]? {
        guard text.utf8.count <= maxMetadataBytes else { return nil }
        let scalars = text.unicodeScalars
        var found: [Frame] = []
        var index = scalars.startIndex
        while index < scalars.endIndex {
            guard scalars[index] == "{" else {
                index = scalars.index(after: index)
                continue
            }
            var nameStart = index
            var length = 0
            while nameStart > scalars.startIndex, length < 127 {
                let previous = scalars.index(before: nameStart)
                let scalar = scalars[previous]
                guard scalar.isASCII, scalar.properties.isAlphabetic
                        || ("0"..."9").contains(scalar) || scalar == "_"
                else { break }
                nameStart = previous
                length += 1
            }
            guard length > 0, nameStart > scalars.startIndex,
                  scalars[scalars.index(before: nameStart)].value == UInt32(length)
            else {
                index = scalars.index(after: index)
                continue
            }
            guard let parsed = StrictJSONObject.parse(in: text, from: index) else { return nil }
            found.append((String(scalars[nameStart..<index]), parsed.object))
            if found.count > 1 { return found }
            index = parsed.end
        }
        return found
    }

    private nonisolated static func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: needle, options: .literal, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// The object opened by the first `{` in the text, parsed with the key
    /// rules, or nil. Nothing precedes that brace that could enclose it, so
    /// it is never an object nested inside another one; the last brace
    /// before a key, which the unframed reading once used, can be.
    private nonisolated static func outermostObject(in text: String) -> [String: Any]? {
        guard let open = text.unicodeScalars.firstIndex(of: "{") else { return nil }
        return StrictJSONObject.parse(in: text, from: open)?.object
    }

    /// Finds the JSON object that opens immediately before `key` and
    /// returns it parsed. Brace counting has to respect strings, since the
    /// questions themselves contain braces and quotes, so it goes through
    /// `StrictJSONObject`'s scalar scan. Searched literally, so a quote or
    /// brace with a mark fused onto it is still found.
    ///
    /// Lenient, and only ever used for the summary, which is context: the
    /// object it finds can be nested inside the call's arguments, so it is
    /// never what Approve is shown beside.
    nonisolated static func embeddedJSONObject(
        in text: String, containingKey key: String
    ) -> [String: Any]? {
        guard let keyRange = text.range(of: key, options: .literal) else { return nil }
        // The object opens at the last `{` at or before the key.
        guard let open = text.range(
            of: "{", options: [.backwards, .literal], range: text.startIndex..<keyRange.upperBound
        )?.lowerBound else { return nil }
        return StrictJSONObject.parse(in: text, from: open, checkingKeys: false)?.object
    }
}

/// Whether an Antigravity Approve or Deny may be pressed into the screen
/// read at click time.
///
/// The row is a poll behind the terminal. In the seconds between, the call
/// it showed can settle and agy can gate the next one, and the press-time
/// script confirms only an option label and the marked line, which read the
/// same on every gate. So the press goes ahead only when the conversation's
/// newest unsettled step, read again now, is the very call the row showed,
/// and the screen ends in agy's own selector rather than a list the model
/// wrote.
enum AntigravityAnswerCheck {
    nonisolated static func mayAnswer(
        shown: ApprovalPrompt, screen: String, pending: AntigravityConversation.Pending?
    ) -> Bool {
        guard TuiPromptLayout.endsInAgyGate(screen),
              let pending, pending.prompt == shown
        else { return false }
        return pending.question == nil || pending.isApproval
    }

    /// The newest unsettled step of the live conversation behind a row on
    /// this Mac, read from its database now.
    nonisolated static func livePending(sessionID: UUID) -> AntigravityConversation.Pending? {
        let home = AntigravityReader.defaultHome()
        guard let id = AntigravityReader.liveConversations(home: home).keys
            .first(where: { StableID.uuid(for: $0) == sessionID })
        else { return nil }
        return AntigravityConversation.pending(
            dbPath: AntigravityConversation.conversationPath(home: home, conversationID: id).path)
    }
}
