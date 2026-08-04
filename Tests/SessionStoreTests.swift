import Foundation
import Testing
@testable import SwarmBar

@MainActor
struct SessionStoreTests {
    private func session(_ status: SessionStatus, path: URL? = nil) -> AgentSession {
        AgentSession(tool: .claudeCode, projectName: "proj", projectPath: path, status: status)
    }

    @Test func sectionDerivation() {
        let store = SessionStore()
        let approval = session(.waitingApproval(command: "rm -rf /tmp/x"))
        let input = session(.waitingInput(prompt: "Which one?"))
        let working = session(.working(activity: "Editing"))
        let tooling = session(.runningTool(activity: "Running swift build"))
        let idle = session(.idle)
        let done = session(.done(summary: "Merged"))
        for s in [approval, input, working, tooling, idle, done] { store.upsert(s) }

        #expect(Set(store.attention.map(\.id)) == Set([approval.id, input.id]))
        #expect(Set(store.active.map(\.id)) == Set([working.id, tooling.id]))
        #expect(Set(store.recent.map(\.id)) == Set([idle.id, done.id]))

        // A finished turn whose process still runs is Active, not history.
        var liveDone = AgentSession(
            tool: .claudeCode, projectName: "proj",
            status: .done(summary: "Shipped."), processAlive: true)
        store.upsert(liveDone)
        #expect(store.active.contains { $0.id == liveDone.id })
        #expect(!store.recent.contains { $0.id == liveDone.id })
        liveDone.processAlive = false
        store.upsert(liveDone)
        #expect(store.recent.contains { $0.id == liveDone.id })
        #expect(store.anyActive)
        #expect(store.attentionCount == 2)
    }

    @Test func recentCollapsesLaunchScopedToolTrails() {
        let store = SessionStore()
        let old = AgentSession(
            tool: .grokBuild, projectName: "zach", status: .idle,
            lastActivityAt: .now.addingTimeInterval(-30 * 60))
        let newer = AgentSession(
            tool: .grokBuild, projectName: "zach", status: .idle,
            lastActivityAt: .now)
        let claudeA = AgentSession(
            tool: .claudeCode, projectName: "zach", status: .idle,
            lastActivityAt: .now.addingTimeInterval(-30 * 60))
        let claudeB = AgentSession(
            tool: .claudeCode, projectName: "zach", status: .idle,
            lastActivityAt: .now)
        for s in [old, newer, claudeA, claudeB] { store.upsert(s) }

        let recentIds = Set(store.recent.map(\.id))
        #expect(recentIds == Set([newer.id, claudeA.id, claudeB.id]))
    }

    @Test func endedSessionsStayIdleThroughResync() {
        let store = SessionStore()
        let s = AgentSession(
            tool: .claudeCode, projectName: "proj",
            status: .waitingInput(prompt: "still there?"), lastActivityAt: .now)
        store.upsert(s)
        store.markSessionEnded(s.id)
        #expect(store.sessions.first?.status == .idle)

        // The transcript still looks fresh on the next poll; the ended
        // marker has to win over the parser's waiting verdict.
        var fresh = s
        fresh.status = .waitingInput(prompt: "still there?")
        store.sync(tool: .claudeCode, sessions: [fresh])
        #expect(store.sessions.first?.status == .idle)
    }

    @Test func recentDropsSessionsPastRetention() {
        let store = SessionStore()
        let fresh = session(.idle)
        var stale = AgentSession(
            tool: .claudeCode, projectName: "old-proj", status: .idle,
            lastActivityAt: .now.addingTimeInterval(-SessionStore.recentRetention - 60))
        stale.startedAt = stale.lastActivityAt
        for s in [fresh, stale] { store.upsert(s) }

        #expect(store.recent.map(\.id) == [fresh.id])
        #expect(store.visibleCount == 1)
    }

    @Test func upsertMergesAndPreservesStartedAt() {
        let store = SessionStore()
        let original = AgentSession(
            tool: .codex, projectName: "proj",
            status: .working(activity: "a"),
            startedAt: Date(timeIntervalSinceNow: -600)
        )
        store.upsert(original)

        var updated = original
        updated.status = .runningTool(activity: "b")
        updated.startedAt = .now
        store.upsert(updated)

        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].status == .runningTool(activity: "b"))
        #expect(store.sessions[0].startedAt == original.startedAt)
    }

    @Test func mockApprovalTransitions() {
        let store = SessionStore()
        let approval = session(.waitingApproval(command: "git push origin main"))
        store.upsert(approval)

        store.approve(approval)
        #expect(store.sessions[0].status == .runningTool(activity: "Running git"))

        let denyTarget = session(.waitingApproval(command: "rm -rf x"))
        store.upsert(denyTarget)
        store.deny(denyTarget)
        #expect(store.sessions.first { $0.id == denyTarget.id }?.status
                == .working(activity: "Rethinking approach without that command…"))
    }

    @Test func statusFlags() {
        #expect(SessionStatus.waitingApproval(command: "x").needsAttention)
        #expect(SessionStatus.waitingInput(prompt: "x").needsAttention)
        #expect(!SessionStatus.working(activity: "x").needsAttention)
        #expect(SessionStatus.working(activity: "x").isActive)
        #expect(SessionStatus.runningTool(activity: "x").isActive)
        #expect(!SessionStatus.idle.isActive)
        #expect(!SessionStatus.done(summary: "x").isActive)
    }
}

@MainActor
struct AttentionAlertTests {
    private func approval(_ command: String) -> AgentSession {
        AgentSession(
            tool: .claudeCode, projectName: "proj",
            projectPath: URL(fileURLWithPath: "/tmp/proj"),
            status: .waitingApproval(command: command))
    }

    @Test func alertsOnceWhileAnApprovalStaysPending() {
        let store = SessionStore()
        var alerts: [AgentSession] = []
        store.attentionAlertHandler = { alerts.append($0) }

        let pending = approval("git push origin main")
        store.applyHookEvent(
            sessionID: pending.id, tool: .claudeCode,
            status: .waitingApproval(command: "git push origin main"),
            sticky: true, cwd: "/tmp/proj", accountLabel: nil)
        #expect(alerts.count == 1)

        // Three polls where the transcript still reads as a running tool.
        var polled = pending
        polled.status = .runningTool(activity: "Running git")
        for _ in 0..<3 {
            store.sync(tool: .claudeCode, sessions: [polled])
        }
        #expect(alerts.count == 1)
    }

    @Test func alertsAgainAfterTheApprovalResolves() {
        let store = SessionStore()
        var alerts: [AgentSession] = []
        store.attentionAlertHandler = { alerts.append($0) }

        let s = approval("rm -rf /tmp/x")
        store.applyHookEvent(
            sessionID: s.id, tool: .claudeCode,
            status: .waitingApproval(command: "rm -rf /tmp/x"),
            sticky: true, cwd: "/tmp/proj", accountLabel: nil)
        #expect(alerts.count == 1)

        // Resolved: the override clears and a poll shows it working.
        store.clearHookOverride(sessionID: s.id)
        var working = s
        working.status = .working(activity: "Working…")
        store.sync(tool: .claudeCode, sessions: [working])
        #expect(alerts.count == 1)

        // A second, later approval on the same session alerts again.
        store.applyHookEvent(
            sessionID: s.id, tool: .claudeCode,
            status: .waitingApproval(command: "curl example.com"),
            sticky: true, cwd: "/tmp/proj", accountLabel: nil)
        #expect(alerts.count == 2)
    }

    @Test func doesNotRealertADismissedWaitingRow() {
        let store = SessionStore()
        var alerts: [AgentSession] = []
        store.attentionAlertHandler = { alerts.append($0) }

        var s = AgentSession(
            tool: .claudeCode, projectName: "proj",
            status: .waitingInput(prompt: "Which one?"),
            lastActivityAt: .now)
        store.upsert(s)
        #expect(alerts.count == 1)

        store.acknowledge(store.sessions[0])
        // The unchanged transcript keeps re-deriving the waiting verdict.
        s.status = .waitingInput(prompt: "Which one?")
        for _ in 0..<3 { store.sync(tool: .claudeCode, sessions: [s]) }
        #expect(alerts.count == 1)
    }
}
