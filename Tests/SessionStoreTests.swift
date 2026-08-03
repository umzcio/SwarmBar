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
        #expect(store.anyActive)
        #expect(store.attentionCount == 2)
    }

    @Test func recentCollapsesLaunchScopedToolTrails() {
        let store = SessionStore()
        let old = AgentSession(
            tool: .grokBuild, projectName: "zach", status: .idle,
            lastActivityAt: .now.addingTimeInterval(-3600))
        let newer = AgentSession(
            tool: .grokBuild, projectName: "zach", status: .idle,
            lastActivityAt: .now)
        let claudeA = AgentSession(
            tool: .claudeCode, projectName: "zach", status: .idle,
            lastActivityAt: .now.addingTimeInterval(-3600))
        let claudeB = AgentSession(
            tool: .claudeCode, projectName: "zach", status: .idle,
            lastActivityAt: .now)
        for s in [old, newer, claudeA, claudeB] { store.upsert(s) }

        let recentIds = Set(store.recent.map(\.id))
        #expect(recentIds == Set([newer.id, claudeA.id, claudeB.id]))
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
