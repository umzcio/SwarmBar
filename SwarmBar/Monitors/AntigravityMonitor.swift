import Foundation

/// Turns Antigravity's conversation rows into sessions.
///
/// Phase 1 deliberately stops at listing them. Approve and deny are not
/// wired: `agy --dangerously-skip-permissions` proves a permission prompt
/// exists, and the binary contains Claude's hook event names alongside a
/// `plugin import claude` command, which suggests the Claude-compatible
/// bridge SwarmBar already speaks. None of that is verified, and answering
/// a real prompt wrongly is the one mistake in this app that cannot be
/// taken back, so it waits for a live round.
struct AntigravityMonitor: SessionMonitor {
    /// Matches the other monitors: a conversation untouched for longer than
    /// this is history, not status.
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let sessions = await Task.detached { Self.discover(now: now) }.value
                store.sync(tool: .antigravity, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func discover(
        rows: [AntigravityReader.Row] = AntigravityReader.rows(),
        now: Date
    ) -> [AgentSession] {
        // A subagent names its parent, so the parent declares nothing and
        // the child declares itself. Same conclusion as every other tool:
        // read the tool's own statement of parentage, never infer it.
        let sessions = rows.filter { $0.parentID.isEmpty }

        return sessions.compactMap { row -> AgentSession? in
            let age = now.timeIntervalSince(row.lastModified)
            guard age >= 0, age < discoveryWindow else { return nil }
            let path = row.workspace.map { URL(fileURLWithPath: $0) }
            return AgentSession(
                id: StableID.uuid(for: row.conversationID),
                tool: .antigravity,
                projectName: path?.lastPathComponent
                    ?? (row.title.isEmpty ? "agy session" : row.title),
                projectPath: path,
                status: AntigravitySessionState.status(for: row, age: age),
                startedAt: row.lastModified,
                lastActivityAt: row.lastModified,
                title: row.title.isEmpty ? nil : row.title,
                processAlive: AntigravitySessionState.isAlive(row, age: age)
            )
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}

/// The interpretation half, kept separate and pure so it can be tested and,
/// more importantly, corrected once real sessions have been sampled.
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
