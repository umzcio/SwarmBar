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

    // The compact row's badge is the only place a remote session's host
    // reaches VoiceOver (see CompactSessionRow.swift): its accessibility
    // label is `unreachableNote(...) ?? badge(...)`, composed from the two
    // functions above rather than a third one. These tests pin that exact
    // composition, in the same style as the five above.

    @Test("the badge announcement carries the host and the unreachable reason")
    func badgeAnnouncementCarriesUnreachableReason() {
        let s = session(host: "umzcaio")
        let announcement = RemoteRowLabel.unreachableNote(
            host: s.host, reachability: ["umzcaio": .unreachable("closed")]
        ) ?? RemoteRowLabel.badge(for: s)
        #expect(announcement == "Cannot reach umzcaio")
    }

    @Test("the badge announcement is just the host when reachable")
    func badgeAnnouncementIsHostWhenReachable() {
        let s = session(host: "umzcaio")
        let announcement = RemoteRowLabel.unreachableNote(
            host: s.host, reachability: ["umzcaio": .reachable]
        ) ?? RemoteRowLabel.badge(for: s)
        #expect(announcement == "umzcaio")
    }
}
