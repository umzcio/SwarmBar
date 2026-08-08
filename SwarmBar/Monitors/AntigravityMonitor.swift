import Foundation

/// Turns Antigravity conversations into sessions.
///
/// Antigravity is unusual in splitting live state from finished state
/// completely, and the split is what this monitor is built around.
///
/// A conversation gains its row in `conversation_summaries.db` when it
/// ENDS. While it runs there is no row at all, so the first version of this
/// monitor, which read only that table, listed finished conversations and
/// showed nothing in progress: the exact opposite of what a status bar is
/// for. Live sessions come from three files instead:
///
/// - `presence/<id>.lock`, held open for the life of the session, which
///   names the conversation and hands over the pid running it,
/// - `history.jsonl`, the only record of a running conversation's
///   workspace,
/// - `brain/<id>/.system_generated/logs/transcript.jsonl`, one named step
///   per line, which gives the status.
///
/// The summaries table is still read, for conversations that have ended
/// recently enough to belong in Recent.
///
/// Approve and deny are not wired. `agy --dangerously-skip-permissions`
/// proves a permission prompt exists, and the conversation database has a
/// `permissions` blob per step, but no sample of a pending one has been
/// captured. Answering a real prompt wrongly is the one mistake in this app
/// that cannot be taken back, so it waits for a live round.
struct AntigravityMonitor: SessionMonitor {
    /// Matches the other monitors: a conversation untouched for longer than
    /// this is history, not status.
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let sessions = await Task.detached {
                    let home = AntigravityReader.defaultHome()
                    return Self.discover(
                        home: home,
                        rows: AntigravityReader.rows(),
                        live: AntigravityReader.liveConversations(home: home),
                        history: AntigravityReader.history(
                            atPath: home.appendingPathComponent("history.jsonl").path),
                        now: now
                    )
                }.value
                store.sync(tool: .antigravity, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Defaults are inert rather than live, so a test that supplies one
    /// input does not silently pick up this machine's real sessions through
    /// the others.
    nonisolated static func discover(
        home: URL = AntigravityReader.defaultHome(),
        rows: [AntigravityReader.Row] = [],
        live: [String: Int] = [:],
        history: [String: AntigravityReader.HistoryEntry] = [:],
        transcript: (URL) -> String? = { ClaudeCodeMonitor.tail(of: $0) },
        now: Date
    ) -> [AgentSession] {
        var sessions: [AgentSession] = []

        for (id, pid) in live {
            let entry = history[id]
            let steps = transcript(
                AntigravityReader.transcriptPath(home: home, conversationID: id)
            ).map(AntigravityTranscript.steps(in:)) ?? []
            // A session whose process is alive belongs in Active even
            // between turns, so there is no discovery window here: the lock
            // is the evidence, and it outranks any timestamp.
            sessions.append(session(
                id: id,
                workspace: entry?.workspace,
                title: nil,
                status: AntigravityTranscript.status(for: steps)
                    ?? .working(activity: entry?.prompt ?? "Working…"),
                lastActivity: steps.last?.createdAt ?? entry?.sentAt ?? now,
                pid: pid,
                alive: true
            ))
        }

        for row in rows where live[row.conversationID] == nil {
            let age = now.timeIntervalSince(row.lastModified)
            guard age >= 0, age < discoveryWindow else { continue }
            // A subagent names its parent, so the parent declares nothing
            // and the child declares itself. Same conclusion as every other
            // tool: read the tool's own statement of parentage, never infer
            // it.
            guard row.parentID.isEmpty else { continue }
            sessions.append(session(
                id: row.conversationID,
                workspace: row.workspace ?? history[row.conversationID]?.workspace,
                title: row.title.isEmpty ? nil : row.title,
                status: AntigravitySessionState.status(for: row, age: age),
                lastActivity: row.lastModified,
                pid: nil,
                alive: AntigravitySessionState.isAlive(row, age: age)
            ))
        }

        return sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private nonisolated static func session(
        id: String,
        workspace: String?,
        title: String?,
        status: SessionStatus,
        lastActivity: Date,
        pid: Int?,
        alive: Bool
    ) -> AgentSession {
        let path = workspace.map { URL(fileURLWithPath: $0) }
        return AgentSession(
            id: StableID.uuid(for: id),
            tool: .antigravity,
            projectName: path?.lastPathComponent
                ?? (title.map { $0.isEmpty ? nil : $0 } ?? nil)
                ?? "agy session",
            projectPath: path,
            status: status,
            startedAt: lastActivity,
            lastActivityAt: lastActivity,
            pid: pid.map { pid_t($0) },
            title: title,
            processAlive: alive
        )
    }
}

/// The interpretation half for FINISHED conversations, the ones read from
/// the summaries table. A live session's status comes from its transcript
/// instead, which names its states rather than numbering them.
///
/// Kept separate and pure so it can be tested and, more importantly,
/// corrected once real values have been sampled.
enum AntigravitySessionState {
    /// How recently a conversation must have moved to count as working,
    /// when the database offers nothing better.
    static let activeAfter: TimeInterval = 2 * 60

    /// `not_fully_idle` reads as the flag that means a turn is in flight,
    /// and `killed` as the session being over. Neither has ever been
    /// observed as anything but 0 here, so both are treated as hints that
    /// refine recency rather than as the source of truth. When a live
    /// session finally sets them, this is the function to revisit, and the
    /// `status` string is the field most likely to replace it outright.
    static func status(for row: AntigravityReader.Row, age: TimeInterval) -> SessionStatus {
        if row.killed { return .done(summary: summary(row)) }
        if let mapped = mappedStatus(row.status, row: row) { return mapped }
        if row.notFullyIdle { return .working(activity: activity(row)) }
        if age < activeAfter { return .working(activity: activity(row)) }
        return .idle
    }

    /// Every row sampled so far has an empty `status`, so this maps only
    /// what the column plausibly contains and returns nil otherwise. Nil
    /// means "no opinion", which falls through to recency, so an unknown
    /// value can never invent a state.
    static func mappedStatus(_ raw: String, row: AntigravityReader.Row) -> SessionStatus? {
        switch raw.lowercased() {
        case "":                       return nil
        case "running", "active", "in_progress", "working":
            return .working(activity: activity(row))
        case "waiting", "awaiting_input", "needs_input":
            return .waitingInput(prompt: row.preview)
        case "done", "complete", "completed", "finished", "idle":
            return .done(summary: summary(row))
        default:                       return nil
        }
    }

    static func isAlive(_ row: AntigravityReader.Row, age: TimeInterval) -> Bool {
        if row.killed { return false }
        return row.notFullyIdle || age < activeAfter
    }

    private static func activity(_ row: AntigravityReader.Row) -> String {
        row.preview.isEmpty ? "Working…" : row.preview
    }

    private static func summary(_ row: AntigravityReader.Row) -> String {
        row.preview.isEmpty ? "Finished" : row.preview
    }
}
