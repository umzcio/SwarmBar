import Foundation
import Testing
@testable import SwarmBar

@Suite("Remote row labelling")
struct RemoteRowTests {
    private func session(host: String?) -> AgentSession {
        AgentSession(
            id: UUID(), tool: .claudeCode, projectName: "AIF",
            status: .working(activity: "thinking"), host: host
        )
    }

    @Test("a local session shows no host badge")
    func localHasNoBadge() {
        #expect(RemoteRowLabel.badge(for: session(host: nil)) == nil)
    }

    @Test("a remote session shows its host as the badge")
    func remoteShowsHost() {
        #expect(RemoteRowLabel.badge(for: session(host: "umzcaio")) == "umzcaio")
    }

    @Test("an unreachable host says so in sentence case with no em dash")
    func unreachableNote() {
        let note = RemoteRowLabel.unreachableNote(
            host: "umzcaio", reachability: ["umzcaio": .unreachable("closed")])
        #expect(note == "Cannot reach umzcaio")
        #expect(!(note ?? "").contains("—"))
    }

    @Test("a reachable host adds no note")
    func reachableHasNoNote() {
        #expect(RemoteRowLabel.unreachableNote(
            host: "umzcaio", reachability: ["umzcaio": .reachable]) == nil)
    }

    @Test("a local session never gets an unreachable note")
    func localNeverUnreachable() {
        #expect(RemoteRowLabel.unreachableNote(
            host: nil, reachability: ["umzcaio": .unreachable("closed")]) == nil)
    }
}
