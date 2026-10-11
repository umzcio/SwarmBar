import Foundation
import Network
import Testing
@testable import SwarmBar

@MainActor
struct NotificationRegressionTests {
    private func store() -> SessionStore {
        SessionStore(defaults: UserDefaults(suiteName: "NotificationTests.\(UUID())")!)
    }

    @Test func codexFinalQuestionNeedsAttention() throws {
        let tail = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Which region should I use?"}}"#
        let status = try #require(CodexSessionParser.parse(tail: tail))
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        store.upsert(AgentSession(tool: .codex, projectName: "test", status: status))
        #expect(status == .waitingInput(prompt: "Which region should I use?"))
        #expect(alerts == 1)
    }

    @Test func codexQuestionBeyondPreviewStillNeedsAttention() throws {
        let message = String(repeating: "Completed work. ", count: 10) + "Ship it?"
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg", "payload": ["type": "task_complete", "last_agent_message": message]
        ])
        let status = try #require(CodexSessionParser.parse(tail: String(decoding: data, as: UTF8.self)))
        #expect(status.needsAttention)
    }

    @Test func metadataDoesNotRepeatAnUnansweredQuestion() throws {
        let tail = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Which region?"}]}}"#
        let before = try #require(ClaudeSessionParser.parse(tail: tail))
        let after = try #require(ClaudeSessionParser.parse(
            tail: tail + "\n" + #"{"type":"system","subtype":"turn_duration","durationMs":1500}"#))
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        var session = AgentSession(tool: .claudeCode, projectName: "test", status: before.status,
            attentionEventID: before.attentionEventID)
        store.sync(tool: .claudeCode, sessions: [session])
        session.status = after.status
        session.attentionEventID = after.attentionEventID
        session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .claudeCode, sessions: [session])
        #expect(alerts == 1)
    }

    @Test func newQuestionAfterDismissalAlertsOnce() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        var session = AgentSession(tool: .claudeCode, projectName: "test", status: .waitingInput(prompt: "First?"))
        store.sync(tool: .claudeCode, sessions: [session])
        store.acknowledge(session)
        session.status = .waitingInput(prompt: "Second?")
        session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .claudeCode, sessions: [session])
        #expect(alerts == 2)
    }

    @Test func hookOverridePreventsTransientQuestionAlert() {
        let store = store()
        var alerts: [SessionStatus] = []
        store.attentionAlertHandler = { alerts.append($0.status) }
        let id = UUID()
        store.applyHookEvent(sessionID: id, tool: .claudeCode,
            status: .waitingApproval(command: "command"), sticky: true, cwd: nil, accountLabel: nil)
        var session = store.sessions[0]
        session.status = .waitingInput(prompt: "Old question?")
        session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .claudeCode, sessions: [session])
        #expect(alerts == [.waitingApproval(command: "command")])
    }

    @Test func pendingHookApprovalDoesNotRepeatWhenTranscriptMoves() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        store.applyHookEvent(sessionID: UUID(), tool: .claudeCode,
            status: .waitingApproval(command: "command"), sticky: true, cwd: nil, accountLabel: nil)
        var session = store.sessions[0]
        session.status = .runningTool(activity: "command")
        for _ in 0..<3 {
            session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
            store.sync(tool: .claudeCode, sessions: [session])
        }
        #expect(alerts == 1)
    }

    @Test func identicalQuestionInANewTurnStillAlerts() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        var session = AgentSession(tool: .claudeCode, projectName: "test", status: .waitingInput(prompt: "Continue?"))
        store.sync(tool: .claudeCode, sessions: [session])
        session.status = .working(activity: "Thinking")
        session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .claudeCode, sessions: [session])
        session.status = .waitingInput(prompt: "Continue?")
        session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .claudeCode, sessions: [session])
        #expect(alerts == 2)
    }

    @Test func twoIdenticalApprovalHooksBothAlert() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        let id = UUID()
        for _ in 0..<2 {
            store.applyHookEvent(sessionID: id, tool: .claudeCode,
                status: .waitingApproval(command: "command"), sticky: true, cwd: nil, accountLabel: nil)
            store.clearHookOverride(sessionID: id)
        }
        #expect(alerts == 2)
    }

    @Test func metadataDoesNotUndoDismissal() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        var session = AgentSession(tool: .claudeCode, projectName: "test", status: .waitingInput(prompt: "Continue?"),
            attentionEventID: "question")
        store.sync(tool: .claudeCode, sessions: [session])
        store.acknowledge(session)
        session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .claudeCode, sessions: [session])
        #expect(alerts == 1)
        #expect(store.attention.isEmpty)
    }

    private func remoteQuestion(event: String, modified: Date) throws -> AgentSession {
        let tail = #"{"uuid":"\#(event)","type":"assistant","message":{"content":[{"type":"text","text":"Continue?"}]}}"#
        let snapshot = RemoteSnapshot(ok: true, protocolVersion: 2, hostname: "host", system: "Linux",
            now: modified.timeIntervalSince1970, roots: [], sessions: [
                RemoteSessionRecord(tool: "claudeCode", path: "/session.jsonl", root: "/", projectDir: "-test",
                    mtime: modified.timeIntervalSince1970, created: nil, size: tail.utf8.count, tail: tail)
            ], processes: [], processesFailed: false, warnings: [])
        return try #require(RemoteSnapshot.sessions(from: snapshot, host: "host", now: modified).first)
    }

    @Test func identicalQuestionsBetweenPollsHaveDistinctEvents() throws {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        let at = Date.now
        store.sync(tool: .claudeCode, host: "host", sessions: [try remoteQuestion(event: "first", modified: at)])
        store.sync(tool: .claudeCode, host: "host", sessions: [try remoteQuestion(event: "second", modified: at.addingTimeInterval(1))])
        #expect(alerts == 2)
    }

    @Test func sameRemoteEventIgnoresFileTimestampChanges() throws {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        let at = Date.now
        for offset in 0..<3 {
            store.sync(tool: .claudeCode, host: "host", sessions: [
                try remoteQuestion(event: "first", modified: at.addingTimeInterval(Double(offset)))
            ])
        }
        #expect(alerts == 1)
    }

    private func stop(_ store: SessionStore, id: UUID) {
        let server = HookServer(store: store)
        // Routing is synchronous. An unstarted connection cannot send to
        // a live bridge or receive an approval; only store effects matter.
        let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
        defer { connection.cancel() }
        server.route(.init(path: "/hook/Stop", accountLabel: nil, token: nil,
            body: ["session_id": id.uuidString]), connection: connection)
    }

    @Test func stopDoesNotInventAQuestionForACompletedReport() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        let session = AgentSession(tool: .claudeCode, projectName: "test", status: .done(summary: "Implemented and tested."))
        store.upsert(session)
        stop(store, id: session.id)
        #expect(alerts == 0)
        #expect(store.sessions[0].status == .done(summary: "Implemented and tested."))
    }

    @Test func stopReleasesWorkingOverrideSoPollingCanFindAQuestion() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        let id = UUID()
        store.applyHookEvent(sessionID: id, tool: .claudeCode,
            status: .working(activity: "Thinking"), sticky: false, cwd: nil, accountLabel: nil)
        stop(store, id: id)
        #expect(alerts == 0)
        #expect(store.hookOverrides[id] == nil)
        var session = store.sessions[0]
        session.status = .waitingInput(prompt: "Continue?")
        store.sync(tool: .claudeCode, sessions: [session])
        #expect(alerts == 1)
        #expect(store.attention.first?.status == .waitingInput(prompt: "Continue?"))
    }

    @Test func clearingAnOldDismissalDoesNotResendANewerApproval() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        let session = AgentSession(tool: .claudeCode, projectName: "test", status: .waitingInput(prompt: "Continue?"))
        store.upsert(session)
        store.acknowledge(session)
        store.applyHookEvent(sessionID: session.id, tool: .claudeCode,
            status: .waitingApproval(command: "command"), sticky: true, cwd: nil, accountLabel: nil)
        var poll = session
        poll.status = .runningTool(activity: "command")
        poll.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .claudeCode, sessions: [poll])
        #expect(alerts == 2)
    }

    @Test func codexSameCommandWithNewCallIDAlertsAgain() throws {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        let id = UUID()
        for call in ["first", "second"] {
            let tail = #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"\#(call)","arguments":"{\"cmd\":\"echo hello\",\"sandbox_permissions\":\"require_escalated\"}"}}"#
            let parsed = try #require(CodexSessionParser.parseDetails(tail: tail))
            store.sync(tool: .codex, sessions: [AgentSession(id: id, tool: .codex,
                projectName: "test", status: parsed.status, attentionEventID: parsed.attentionEventID)])
        }
        #expect(alerts == 2)
    }

    @Test func codexStaleQuestionDoesNotAskForAttention() throws {
        let tail = #"{"timestamp":"2026-08-01T10:00:00.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Continue?"}}"#
        let now = try #require(ClaudeSessionParser.date("2026-08-01T11:00:00.000Z"))
        #expect(CodexSessionParser.parse(tail: tail, now: now) == .idle)
    }

    @Test func delayedPollDoesNotReplayAQuestionAfterAnApproval() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        var question = AgentSession(tool: .claudeCode, projectName: "test",
            status: .waitingInput(prompt: "Continue?"), lastActivityAt: .now.addingTimeInterval(-60),
            attentionEventID: "question")
        store.sync(tool: .claudeCode, sessions: [question])
        store.applyHookEvent(sessionID: question.id, tool: .claudeCode,
            status: .waitingApproval(command: "command"), sticky: true, cwd: nil, accountLabel: nil)
        store.clearHookOverride(sessionID: question.id)
        store.sync(tool: .claudeCode, sessions: [question])
        #expect(alerts == 2)
        // Even metadata giving the old question a newer mtime must not
        // turn it into a new request after the hook has been resolved.
        question.lastActivityAt = .now.addingTimeInterval(1)
        store.sync(tool: .claudeCode, sessions: [question])
        #expect(alerts == 2)
    }

    @Test func providersWithoutEventIDsKeepAnnouncingNewerRequests() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        var session = AgentSession(tool: .kimiCode, projectName: "test", status: .waitingInput(prompt: "Continue?"))
        store.sync(tool: .kimiCode, sessions: [session])
        session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .kimiCode, sessions: [session])
        #expect(alerts == 2)
    }

    @Test func providersWithoutEventIDsCanAskAgainAfterDismissal() {
        let store = store()
        var alerts = 0
        store.attentionAlertHandler = { _ in alerts += 1 }
        var session = AgentSession(tool: .kimiCode, projectName: "test", status: .waitingInput(prompt: "Continue?"))
        store.sync(tool: .kimiCode, sessions: [session])
        store.acknowledge(session)
        session.lastActivityAt = session.lastActivityAt.addingTimeInterval(1)
        store.sync(tool: .kimiCode, sessions: [session])
        #expect(alerts == 2)
        #expect(store.attention.count == 1)
    }

}

/// A finished turn whose process is still open is an agent waiting on the
/// user. Six of seven tools classify that as "done" unless the last message
/// contains a question mark, which caught about a quarter of real turn
/// endings, so the reminder is keyed on the state every monitor reports,
/// not on any one provider's signal.
@MainActor
struct IdleTurnReminderTests {
    private func store() -> SessionStore {
        let s = SessionStore(defaults: UserDefaults(suiteName: "IdleTurn.\(UUID())")!)
        s.launchedAt = .distantPast
        return s
    }

    private func finished(_ tool: AgentTool, endedAt: Date, alive: Bool = true,
                          id: UUID = UUID(), host: String? = nil) -> AgentSession {
        AgentSession(id: id, tool: tool, projectName: "proj",
                     status: .done(summary: "Here is the plan."),
                     lastActivityAt: endedAt, processAlive: alive, host: host)
    }

    @Test func remindsOnceAfterTheDelayForEveryProvider() {
        let now = Date.now
        for tool in AgentTool.allCases {
            let store = store()
            var reminded: [AgentSession] = []
            store.idleTurnHandler = { reminded.append($0) }
            store.upsert(finished(tool, endedAt: now.addingTimeInterval(-30)))
            store.noteIdleTurns(now: now)
            #expect(reminded.isEmpty, "\(tool) reminded before the delay")
            store.noteIdleTurns(now: now.addingTimeInterval(31))
            #expect(reminded.count == 1, "\(tool) did not remind after the delay")
            store.noteIdleTurns(now: now.addingTimeInterval(120))
            #expect(reminded.count == 1, "\(tool) reminded twice for one turn")
        }
    }

    @Test func remoteSessionsAreRemindedToo() {
        let store = store()
        var count = 0
        store.idleTurnHandler = { _ in count += 1 }
        let now = Date.now
        store.upsert(finished(.claudeCode, endedAt: now.addingTimeInterval(-90), host: "umzcaio"))
        store.noteIdleTurns(now: now)
        #expect(count == 1)
    }

    @Test func aNewTurnEarnsANewReminder() {
        let store = store()
        var count = 0
        store.idleTurnHandler = { _ in count += 1 }
        let id = UUID(), now = Date.now
        store.upsert(finished(.codex, endedAt: now.addingTimeInterval(-90), id: id))
        store.noteIdleTurns(now: now)
        store.upsert(finished(.codex, endedAt: now.addingTimeInterval(10), id: id))
        store.noteIdleTurns(now: now.addingTimeInterval(80))
        #expect(count == 2)
    }

    @Test func turnsThatEndedBeforeLaunchAreNotAnnounced() {
        let store = store()
        var count = 0
        store.idleTurnHandler = { _ in count += 1 }
        let now = Date.now
        store.launchedAt = now.addingTimeInterval(-10)
        store.upsert(finished(.kimiCode, endedAt: now.addingTimeInterval(-3600)))
        store.noteIdleTurns(now: now.addingTimeInterval(600))
        #expect(count == 0)
    }

    @Test func aClosedProcessIsNotWaiting() {
        let store = store()
        var count = 0
        store.idleTurnHandler = { _ in count += 1 }
        let now = Date.now
        store.upsert(finished(.openCode, endedAt: now.addingTimeInterval(-90), alive: false))
        store.noteIdleTurns(now: now)
        #expect(count == 0)
    }

    @Test func aTurnAnnouncedByTheQuestionRuleIsNotRemindedAgain() {
        let store = store()
        var count = 0
        store.idleTurnHandler = { _ in count += 1 }
        let now = Date.now
        store.upsert(AgentSession(tool: .claudeCode, projectName: "p",
                                  status: .waitingInput(prompt: "Which region?"),
                                  lastActivityAt: now.addingTimeInterval(-90), processAlive: true))
        store.noteIdleTurns(now: now)
        #expect(count == 0)
    }

    @Test func aDismissedTurnIsNotRemindedAgain() {
        let store = store()
        var count = 0
        store.idleTurnHandler = { _ in count += 1 }
        let now = Date.now
        let waiting = AgentSession(tool: .claudeCode, projectName: "p",
                                   status: .waitingInput(prompt: "Which region?"),
                                   lastActivityAt: now.addingTimeInterval(-90), processAlive: true)
        store.upsert(waiting)
        store.acknowledge(waiting)
        store.noteIdleTurns(now: now)
        #expect(count == 0)
    }
}

/// Codex 0.157 writes bulk record types the parser does not read
/// (token_count, item_completed, reasoning, token_usage_record). When the
/// last 64KB held only those, the tail parsed to nothing and discovery
/// dropped the session, deleting its row and its alert history. Replayed
/// against a real 48MB rollout that happened on about one poll in ten.
struct CodexTailWindowTests {
    private func rollout(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aTailOfOnlyUnreadRecordsStillFindsTheTurn() throws {
        let stamp = ISO8601DateFormatter().string(from: .now)
        let done = #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Shipped the fix."}}"#
        let noise = #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"pad":"\#(String(repeating: "x", count: 900))"}}}"#
        let file = try rollout([done] + Array(repeating: noise, count: 90))
        defer { try? FileManager.default.removeItem(at: file) }

        let tail = try #require(ClaudeCodeMonitor.tail(of: file))
        #expect(CodexSessionParser.parseDetails(tail: tail, now: .now) == nil,
                "the fixture must reproduce the drop: nothing readable in 64KB")

        let parsed = try #require(CodexMonitor.parsedStatus(of: file, tail: tail, now: .now))
        #expect(parsed.status == .done(summary: "Shipped the fix."))
    }

    @Test func anOrdinaryTailDoesNotReadFurther() throws {
        let stamp = ISO8601DateFormatter().string(from: .now)
        let done = #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Done."}}"#
        let file = try rollout([done])
        defer { try? FileManager.default.removeItem(at: file) }
        let tail = try #require(ClaudeCodeMonitor.tail(of: file))
        #expect(CodexMonitor.parsedStatus(of: file, tail: tail, now: .now)?.status == .done(summary: "Done."))
    }
}

/// A banner for a session the user is already looking at is noise. It is
/// skipped only when that exact session is visible and the user is present;
/// every doubt falls back to notifying.
struct VisibleSessionSuppressionTests {
    private func decide(tty: String? = "ttys004", front: Bool = true,
                        visible: [String] = ["/dev/ttys004"], idle: TimeInterval = 5,
                        locked: Bool = false) -> Bool {
        TerminalFocuser.shouldSkipBanner(sessionTTY: tty, frontmostIsITerm: front,
            visibleTTYs: visible, secondsSinceInput: idle, screenLocked: locked)
    }

    @Test func theSessionOnScreenIsSkipped() { #expect(decide()) }

    @Test func aSplitPaneInTheSameTabCountsAsVisible() {
        #expect(decide(visible: ["/dev/ttys002", "/dev/ttys004"]))
    }

    @Test func aSessionInAnotherTabStillNotifies() {
        #expect(!decide(visible: ["/dev/ttys002"]))
    }

    @Test func iTermNotInFrontStillNotifies() { #expect(!decide(front: false)) }

    /// iTerm2 left in front while the user walked away must not swallow it.
    @Test func anIdleUserStillGetsTheBanner() { #expect(!decide(idle: 61)) }

    @Test func aLockedScreenStillGetsTheBanner() { #expect(!decide(locked: true)) }

    /// No tty means the terminal could not be identified (or the session is
    /// remote), so there is no evidence the user is looking at it.
    @Test func anUnknownTerminalStillNotifies() { #expect(!decide(tty: nil)) }
}
