import Foundation
import Network
import Testing
@testable import SwarmBar

/// Hook events relayed from a host by the helper. Every case here is one
/// where the wrong answer is silent: a Grok prompt held long enough to read
/// as consent, an Approve button that can no longer answer anything, or a
/// row that never stops asking.
@MainActor
struct RemoteHookRelayTests {
    private let hostID = UUID()
    private let home = "/home/u"

    /// A mirror under a temp dir, so the Grok and Kimi lookups read
    /// synthetic state and never a real home.
    private func makeMirror() throws -> RemoteMirror {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-hook-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return RemoteMirror(root: root)
    }

    private func origin(
        mirror: RemoteMirror, peer: [String] = ["curl", "bash", "claude"],
        approvalsOff: Set<AgentTool> = []
    ) -> RemoteHookOrigin {
        RemoteHookOrigin(
            hostID: hostID, hostName: "devbox", home: home,
            mirrorHome: mirror.local(home), peer: peer, approvalsOff: approvalsOff)
    }

    private func permissionBody(_ sessionID: String) -> [String: Any] {
        [
            "session_id": sessionID,
            "tool_name": "Bash",
            "tool_input": ["command": "git push"],
            "cwd": "/home/u/proj",
        ]
    }

    private func rowID(_ raw: String) -> UUID {
        RemoteIdentity.sessionID(
            hostID: hostID, home: home,
            localID: UUID(uuidString: raw) ?? StableID.uuid(for: raw))
    }

    private func decode(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["unparsed": true]
    }

    private func isEmptyAnswer(_ data: Data) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return object?.isEmpty == true
    }

    /// Suite defaults, never the real ones, and a local home under a temp
    /// dir, so the local path's Grok and Kimi lookups read nothing real.
    private func rig(remoteHold: Duration = .seconds(350)) -> (SessionStore, HookServer) {
        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let localHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-hook-local-\(UUID().uuidString)", isDirectory: true)
        let server = HookServer(store: store, remoteDecisionHold: remoteHold, localHome: localHome)
        store.approvalResponder = server
        // Nothing here may ever drive this Mac's terminal.
        store.localAnswerObserver = { _, _ in }
        return (store, server)
    }

    // MARK: - Held approvals

    @Test func claudePermissionIsHeldAndResolved() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []

        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: "work",
            origin: origin(mirror: mirror), rid: "r1", held: true) { json, _ in answers.append(json) }

        let row = try #require(store.sessions.first { $0.id == rowID(raw) })
        #expect(row.status == .waitingApproval(command: "git push"))
        #expect(row.host == "devbox")
        #expect(row.tool == .claudeCode)
        #expect(row.accountLabel == "work")
        // A remote path, kept as given rather than checked against this Mac.
        #expect(row.projectPath?.path == "/home/u/proj")
        #expect(answers.isEmpty)
        #expect(server.isHolding(sessionID: row.id))

        store.approve(row)
        #expect(answers.count == 1)
        let output = decode(answers[0])["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PermissionRequest")
        #expect((output?["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        #expect(!server.isHolding(sessionID: row.id))
    }

    @Test func denySendsTheDenyBehavior() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror), rid: "r1", held: true) { json, _ in answers.append(json) }

        let row = try #require(store.sessions.first { $0.id == rowID(raw) })
        store.deny(row)
        let output = decode(try #require(answers.first))["hookSpecificOutput"] as? [String: Any]
        #expect((output?["decision"] as? [String: Any])?["behavior"] as? String == "deny")
    }

    @Test func openCodePermissionIsHeldAndDenied() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        var answers: [Data] = []
        let body: [String: Any] = [
            "id": "per_1", "sessionID": "ses_abc", "permission": "bash",
            "patterns": ["ls -la"], "directory": "/home/u/web",
        ]
        server.handleRemote(
            event: "OpenCodePermission", body: body, accountLabel: nil,
            origin: origin(mirror: mirror, peer: []), rid: "r2", held: true) { json, _ in answers.append(json) }

        let id = RemoteIdentity.sessionID(
            hostID: hostID, home: home, localID: StableID.uuid(for: "ses_abc"))
        let row = try #require(store.sessions.first { $0.id == id })
        #expect(row.tool == .openCode)
        #expect(row.host == "devbox")
        #expect(answers.isEmpty)

        store.deny(row)
        #expect(decode(try #require(answers.first))["decision"] as? String == "deny")
    }

    // MARK: - Never held

    @Test func grokPeerIsNeverHeld() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror, peer: ["curl", "bash", "grok", "claude"]),
            rid: "r1", held: true) { json, _ in answers.append(json) }

        // Answered before handleRemote returned, so the helper lets go at once.
        #expect(answers.count == 1)
        #expect(isEmptyAnswer(answers[0]))
        #expect(!server.isHolding(sessionID: rowID(raw)))
        #expect(store.sessions.first { $0.id == rowID(raw) }?.status
            == .waitingApproval(command: "git push"))
    }

    @Test func grokSessionFromMirrorIsNeverHeld() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        let grok = try #require(mirror.local(home + "/.grok"))
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [["session_id": raw]])
            .write(to: grok.appendingPathComponent("active_sessions.json"))

        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror), rid: "r1", held: true) { json, _ in answers.append(json) }

        #expect(answers.count == 1)
        #expect(isEmptyAnswer(answers[0]))
        #expect(!server.isHolding(sessionID: rowID(raw)))
        #expect(store.sessions.first { $0.id == rowID(raw) }?.tool == .grokBuild)
    }

    @Test func approvalsOffAnswersEmptyButShowsStatus() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror, approvalsOff: [.claudeCode]),
            rid: "r1", held: true) { json, _ in answers.append(json) }

        #expect(answers.count == 1)
        #expect(isEmptyAnswer(answers[0]))
        #expect(!server.isHolding(sessionID: rowID(raw)))
        #expect(store.sessions.first { $0.id == rowID(raw) }?.status
            == .waitingApproval(command: "git push"))

        var openCodeAnswers: [Data] = []
        server.handleRemote(
            event: "OpenCodePermission",
            body: ["sessionID": "ses_off", "permission": "bash", "patterns": ["ls"]],
            accountLabel: nil, origin: origin(mirror: mirror, peer: [], approvalsOff: [.openCode]),
            rid: "r2", held: true) { json, _ in openCodeAnswers.append(json) }
        #expect(openCodeAnswers.count == 1)
        #expect(isEmptyAnswer(openCodeAnswers[0]))
    }

    /// `held: false` means the helper already answered {}. Nothing waits on
    /// a reply, so sending one would be answering a request that is over.
    @Test func notHeldByTheHelperIsNeverHeldOrAnswered() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror), rid: "r1", held: false) { json, _ in answers.append(json) }

        #expect(answers.isEmpty)
        #expect(!server.isHolding(sessionID: rowID(raw)))
        let row = try #require(store.sessions.first { $0.id == rowID(raw) })
        #expect(row.status == .waitingApproval(command: "git push"))
        #expect(server.resolveApproval(sessionID: row.id, allow: true) == false)
        #expect(answers.isEmpty)
    }

    @Test func statusEventsUpdateTheRowWithoutAnswering() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "UserPromptSubmit", body: ["session_id": raw, "cwd": "/home/u/proj"],
            accountLabel: nil, origin: origin(mirror: mirror), rid: "r1", held: false
        ) { json, _ in answers.append(json) }
        #expect(answers.isEmpty)
        #expect(store.sessions.first { $0.id == rowID(raw) }?.status
            == .working(activity: "Thinking…"))
    }

    /// A home the mirror refuses cannot say which tool a session belongs
    /// to, so nothing is held and no row is invented for it.
    @Test func unmappableHomeIsReleasedAndShowsNothing() throws {
        let (store, server) = rig()
        let raw = UUID().uuidString
        var answers: [Data] = []
        let origin = RemoteHookOrigin(
            hostID: hostID, hostName: "devbox", home: "/home/../etc",
            mirrorHome: nil, peer: ["claude"], approvalsOff: [])
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin, rid: "r1", held: true) { json, _ in answers.append(json) }
        #expect(answers.count == 1)
        #expect(isEmptyAnswer(answers[0]))
        #expect(store.sessions.isEmpty)
    }

    // MARK: - Ending a hold

    @Test func resolvedElsewhereClearsRow() throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror), rid: "r1", held: true) { json, _ in answers.append(json) }
        #expect(server.isHolding(sessionID: rowID(raw)))

        server.cancelRemote(rid: "r1")
        #expect(!server.isHolding(sessionID: rowID(raw)))
        // Settled elsewhere, so the row stops asking for approval.
        #expect(store.sessions.first { $0.id == rowID(raw) }?.status
            == .working(activity: "Working…"))
        // Answered on the host, so nothing is sent back for it.
        #expect(answers.isEmpty)
        #expect(server.resolveApproval(sessionID: rowID(raw), allow: true) == false)
        #expect(answers.isEmpty)
    }

    @Test func holdExpiresAndReleasesTheRow() async throws {
        let (store, server) = rig(remoteHold: .milliseconds(50))
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror), rid: "r1", held: true) { json, _ in answers.append(json) }
        #expect(server.isHolding(sessionID: rowID(raw)))

        let deadline = ContinuousClock.now + .seconds(2)
        while server.isHolding(sessionID: rowID(raw)) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!server.isHolding(sessionID: rowID(raw)))
        // The helper gave up at 345 s, so there is nothing to answer.
        #expect(answers.isEmpty)
        let row = try #require(store.sessions.first { $0.id == rowID(raw) })
        #expect(row.status == .working(activity: "Working…"))
        #expect(server.resolveApproval(sessionID: row.id, allow: true) == false)
    }

    /// A follower that reconnects to its owner replays every open hold. The
    /// same rid must not supersede itself, which would answer it {}.
    @Test func aReplayedRidIsNotAnsweredEmpty() throws {
        let (_, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        for _ in 0..<2 {
            server.handleRemote(
                event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
                origin: origin(mirror: mirror), rid: "r1", held: true) { json, _ in answers.append(json) }
        }
        #expect(answers.isEmpty)
        #expect(server.isHolding(sessionID: rowID(raw)))
    }

    @Test func droppingAHostReleasesItsHoldsWithoutAnswering() throws {
        let (_, server) = rig()
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror), rid: "r1", held: true) { json, _ in answers.append(json) }
        server.dropRemote(hostID: hostID)
        #expect(!server.isHolding(sessionID: rowID(raw)))
        #expect(answers.isEmpty)
    }

    // MARK: - The relay

    @MainActor private final class FakeReplier: RemoteHookReplying {
        var replies: [(rid: String, body: JSONValue)] = []
        var fails = false
        func sendHookReply(rid: String, body: JSONValue) async throws {
            replies.append((rid, body))
            if fails { throw SSHChannelError.closed("synthetic") }
        }
    }

    private func hookLine(
        rid: String, path: String, body: [String: Any], peer: [String], held: Bool,
        generation: Int = 0
    ) throws -> HelperEvent {
        let object: [String: Any] = [
            "event": "hook", "rid": rid, "home": home, "user": "u", "path": path,
            "account": NSNull(), "peer": peer, "body": body, "held": held,
        ]
        return HelperEvent(
            name: "hook", payload: try JSONSerialization.data(withJSONObject: object),
            generation: generation)
    }

    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func relayHoldsThenRepliesWithTheDecision() async throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let replier = FakeReplier()
        let (events, sink) = AsyncStream.makeStream(of: HelperEvent.self)
        let relay = RemoteHookRelay(
            hostID: hostID, hostName: "devbox", mirror: mirror, events: events,
            replier: replier, hookServer: server, approvalsOff: { [] })
        let running = Task { await relay.run() }
        defer { running.cancel() }

        let raw = UUID().uuidString
        sink.yield(try hookLine(
            rid: "abc", path: "/hook/PermissionRequest", body: permissionBody(raw),
            peer: ["curl", "bash", "claude"], held: true))
        await settle { server.isHolding(sessionID: rowID(raw)) }
        let row = try #require(store.sessions.first { $0.id == rowID(raw) })
        #expect(row.host == "devbox")

        store.approve(row)
        await settle { !replier.replies.isEmpty }
        #expect(replier.replies.first?.rid == "abc")
        guard case .object(let body)? = replier.replies.first?.body,
              case .object(let output)? = body["hookSpecificOutput"],
              case .object(let decision)? = output["decision"]
        else {
            Issue.record("reply body is not a hookSpecificOutput decision")
            return
        }
        #expect(decision["behavior"] == .string("allow"))
    }

    @Test func relayRepliesEmptyAtOnceWhenTheMacDeclines() async throws {
        let (_, server) = rig()
        let mirror = try makeMirror()
        let replier = FakeReplier()
        let (events, sink) = AsyncStream.makeStream(of: HelperEvent.self)
        let relay = RemoteHookRelay(
            hostID: hostID, hostName: "devbox", mirror: mirror, events: events,
            replier: replier, hookServer: server, approvalsOff: { [] })
        let running = Task { await relay.run() }
        defer { running.cancel() }

        let raw = UUID().uuidString
        let grok = try #require(mirror.local(home + "/.grok"))
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [["session_id": raw]])
            .write(to: grok.appendingPathComponent("active_sessions.json"))

        sink.yield(try hookLine(
            rid: "g1", path: "/hook/PermissionRequest", body: permissionBody(raw),
            peer: ["curl", "bash", "claude"], held: true))
        await settle { !replier.replies.isEmpty }
        #expect(replier.replies.count == 1)
        #expect(replier.replies.first?.rid == "g1")
        #expect(replier.replies.first?.body == .object([:]))
        #expect(!server.isHolding(sessionID: rowID(raw)))
    }

    @Test func relayNeverRepliesToAnUnheldEvent() async throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let replier = FakeReplier()
        let (events, sink) = AsyncStream.makeStream(of: HelperEvent.self)
        let relay = RemoteHookRelay(
            hostID: hostID, hostName: "devbox", mirror: mirror, events: events,
            replier: replier, hookServer: server, approvalsOff: { [] })
        let running = Task { await relay.run() }
        defer { running.cancel() }

        let raw = UUID().uuidString
        sink.yield(try hookLine(
            rid: "n1", path: "/hook/PermissionRequest", body: permissionBody(raw),
            peer: ["curl", "bash", "claude"], held: false))
        await settle { store.sessions.contains { $0.id == rowID(raw) } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(replier.replies.isEmpty)
        #expect(!server.isHolding(sessionID: rowID(raw)))
    }

    @Test func relayClearsTheHoldOnHookResolved() async throws {
        let (_, server) = rig()
        let mirror = try makeMirror()
        let replier = FakeReplier()
        let (events, sink) = AsyncStream.makeStream(of: HelperEvent.self)
        let relay = RemoteHookRelay(
            hostID: hostID, hostName: "devbox", mirror: mirror, events: events,
            replier: replier, hookServer: server, approvalsOff: { [] })
        let running = Task { await relay.run() }
        defer { running.cancel() }

        let raw = UUID().uuidString
        sink.yield(try hookLine(
            rid: "x1", path: "/hook/PermissionRequest", body: permissionBody(raw),
            peer: ["claude"], held: true))
        await settle { server.isHolding(sessionID: rowID(raw)) }
        sink.yield(HelperEvent(
            name: "hook_resolved", payload: Data(#"{"event":"hook_resolved","rid":"x1"}"#.utf8)))
        await settle { !server.isHolding(sessionID: rowID(raw)) }
        #expect(!server.isHolding(sessionID: rowID(raw)))
        #expect(replier.replies.isEmpty)
    }

    /// Approval switches are read per event, so turning one off in Settings
    /// takes effect for the next prompt without restarting the host.
    @Test func relayReadsApprovalsOffLive() async throws {
        let (_, server) = rig()
        let mirror = try makeMirror()
        let replier = FakeReplier()
        var off: Set<AgentTool> = []
        let (events, sink) = AsyncStream.makeStream(of: HelperEvent.self)
        let relay = RemoteHookRelay(
            hostID: hostID, hostName: "devbox", mirror: mirror, events: events,
            replier: replier, hookServer: server, approvalsOff: { off })
        let running = Task { await relay.run() }
        defer { running.cancel() }

        off = [.claudeCode]
        let raw = UUID().uuidString
        sink.yield(try hookLine(
            rid: "o1", path: "/hook/PermissionRequest", body: permissionBody(raw),
            peer: ["claude"], held: true))
        await settle { !replier.replies.isEmpty }
        #expect(replier.replies.first?.body == .object([:]))
        #expect(!server.isHolding(sessionID: rowID(raw)))
    }

    // MARK: - Review round 1

    /// The helper that held the request is gone, so no reply can land.
    /// Approve must go away at once and pressing it must not claim success.
    @Test func relayDropsHoldsWhenTheHelperExits() async throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let replier = FakeReplier()
        let (events, sink) = AsyncStream.makeStream(of: HelperEvent.self)
        let relay = RemoteHookRelay(
            hostID: hostID, hostName: "devbox", mirror: mirror, events: events,
            replier: replier, hookServer: server, approvalsOff: { [] })
        let running = Task { await relay.run() }
        defer { running.cancel() }

        let raw = UUID().uuidString
        sink.yield(try hookLine(
            rid: "e1", path: "/hook/PermissionRequest", body: permissionBody(raw),
            peer: ["claude"], held: true, generation: 3))
        await settle { server.isHolding(sessionID: rowID(raw)) }
        #expect(server.isHolding(sessionID: rowID(raw)))

        sink.yield(HelperEvent(name: HelperEvent.helperExited, payload: Data(), generation: 3))
        await settle { !server.isHolding(sessionID: rowID(raw)) }
        #expect(!server.isHolding(sessionID: rowID(raw)))
        #expect(server.resolveApproval(sessionID: rowID(raw), allow: true) == false)

        // A line the dead process said before it went, drained late, must
        // not bring the hold back.
        let other = UUID().uuidString
        sink.yield(try hookLine(
            rid: "e2", path: "/hook/PermissionRequest", body: permissionBody(other),
            peer: ["claude"], held: true, generation: 3))
        // A marker from the next process, to know the stale line was seen.
        let marker = UUID().uuidString
        sink.yield(try hookLine(
            rid: "e3", path: "/hook/UserPromptSubmit", body: ["session_id": marker],
            peer: [], held: false, generation: 4))
        await settle { store.sessions.contains { $0.id == rowID(marker) } }
        #expect(!server.isHolding(sessionID: rowID(other)))
        #expect(!store.sessions.contains { $0.id == rowID(other) })
        #expect(replier.replies.isEmpty)
    }

    @Test func relayDropsHoldsWhenTheStreamEnds() async throws {
        let (_, server) = rig()
        let mirror = try makeMirror()
        let replier = FakeReplier()
        let (events, sink) = AsyncStream.makeStream(of: HelperEvent.self)
        let relay = RemoteHookRelay(
            hostID: hostID, hostName: "devbox", mirror: mirror, events: events,
            replier: replier, hookServer: server, approvalsOff: { [] })
        let running = Task { await relay.run() }

        let raw = UUID().uuidString
        sink.yield(try hookLine(
            rid: "s1", path: "/hook/PermissionRequest", body: permissionBody(raw),
            peer: ["claude"], held: true))
        await settle { server.isHolding(sessionID: rowID(raw)) }
        sink.finish()
        await running.value
        #expect(!server.isHolding(sessionID: rowID(raw)))
        #expect(replier.replies.isEmpty)
    }

    @Test func aReplyThatFailsSaysSoOnTheRow() async throws {
        let (store, server) = rig()
        let mirror = try makeMirror()
        let replier = FakeReplier()
        replier.fails = true
        let (events, sink) = AsyncStream.makeStream(of: HelperEvent.self)
        let relay = RemoteHookRelay(
            hostID: hostID, hostName: "devbox", mirror: mirror, events: events,
            replier: replier, hookServer: server, approvalsOff: { [] })
        let running = Task { await relay.run() }
        defer { running.cancel() }

        let raw = UUID().uuidString
        sink.yield(try hookLine(
            rid: "f1", path: "/hook/PermissionRequest", body: permissionBody(raw),
            peer: ["claude"], held: true))
        await settle { server.isHolding(sessionID: rowID(raw)) }
        let row = try #require(store.sessions.first { $0.id == rowID(raw) })
        store.approve(row)
        let undelivered = SessionStatus.waitingInput(
            prompt: "Answer at the terminal, SwarmBar could not deliver")
        await settle { store.sessions.first { $0.id == rowID(raw) }?.status == undelivered }
        #expect(replier.replies.count == 1)
        #expect(store.sessions.first { $0.id == rowID(raw) }?.status == undelivered)
    }

    @Test func aDisabledToolIsNeverHeld() throws {
        let (store, server) = rig()
        store.setToolEnabled(.claudeCode, false)
        store.setToolEnabled(.openCode, false)
        let mirror = try makeMirror()
        let raw = UUID().uuidString
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody(raw), accountLabel: nil,
            origin: origin(mirror: mirror), rid: "d1", held: true) { json, _ in answers.append(json) }
        server.handleRemote(
            event: "OpenCodePermission", body: ["sessionID": "ses_d", "permission": "bash"],
            accountLabel: nil, origin: origin(mirror: mirror, peer: []), rid: "d2", held: true
        ) { json, _ in answers.append(json) }
        #expect(answers.count == 2)
        #expect(answers.allSatisfy(isEmptyAnswer))
        #expect(store.sessions.isEmpty)

        // The local socket takes the same path.
        let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
        defer { connection.cancel() }
        let local = UUID()
        server.route(.init(
            path: "/hook/PermissionRequest", accountLabel: nil, token: nil,
            body: ["session_id": local.uuidString, "tool_name": "Bash",
                   "tool_input": ["command": "ls"]]), connection: connection)
        #expect(!server.isHolding(sessionID: local))
    }

    @Test func pathLikeIdsAreNoTool() throws {
        let mirror = try makeMirror()
        let home = try #require(mirror.local(self.home))
        for raw in ["../x", "a/b", ".", "..", "/etc/passwd", ""] {
            #expect(HookServer.originTool(rawSessionID: raw, home: home) == nil, "\(raw)")
        }
        #expect(HookServer.originTool(rawSessionID: UUID().uuidString, home: home) == .claudeCode)

        let (store, server) = rig()
        var answers: [Data] = []
        server.handleRemote(
            event: "PermissionRequest", body: permissionBody("../../etc"), accountLabel: nil,
            origin: origin(mirror: mirror), rid: "p1", held: true) { json, _ in answers.append(json) }
        #expect(answers.count == 1)
        #expect(isEmptyAnswer(answers[0]))
        #expect(store.sessions.isEmpty)
    }

    /// Approve and Deny on a remote row must never fall through to the
    /// routes that drive a terminal on this Mac.
    @Test func remoteApproveNeverReachesTheLocalTerminal() {
        let (store, _) = rig()
        var routed: [AgentSession] = []
        store.localAnswerObserver = { session, _ in routed.append(session) }
        let remote = AgentSession(
            tool: .kimiCode, projectName: "proj",
            projectPath: URL(fileURLWithPath: "/home/u/proj"),
            status: .waitingApproval(command: "ls"), host: "devbox")
        store.upsert(remote)
        store.approve(remote)
        store.deny(remote)
        #expect(routed.isEmpty)
        #expect(store.sessions.first { $0.id == remote.id }?.status
            == .waitingApproval(command: "ls"))

        // The seam does see a local row, so the empty list above means
        // something.
        let local = AgentSession(
            tool: .kimiCode, projectName: "proj", projectPath: URL(fileURLWithPath: "/tmp"),
            status: .waitingApproval(command: "ls"))
        store.upsert(local)
        store.approve(local)
        #expect(routed.map(\.id) == [local.id])
    }

    /// The local socket path: a held request whose client goes away can no
    /// longer be answered.
    @Test func localHoldEndsWhenItsConnectionDoes() async throws {
        let (_, server) = rig()
        let connection = NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
        defer { connection.cancel() }
        let id = UUID()
        server.route(.init(
            path: "/hook/PermissionRequest", accountLabel: nil, token: nil,
            body: ["session_id": id.uuidString, "tool_name": "Bash",
                   "tool_input": ["command": "ls"]]), connection: connection)
        #expect(server.isHolding(sessionID: id))

        // A connection's state only moves once it has a queue, so it is
        // started here, after routing, and closed at once.
        connection.start(queue: .main)
        connection.cancel()
        await settle { !server.isHolding(sessionID: id) }
        #expect(!server.isHolding(sessionID: id))
        #expect(server.resolveApproval(sessionID: id, allow: true) == false)
    }

    // MARK: - Scripts

    @Test func remoteScriptsNeverTouchLoopback() throws {
        let names = [
            ("swarmbar-remote-hook", "sh"),
            ("swarmbar-remote-kimi-hook", "sh"),
            ("swarmbar-remote-opencode", "js"),
        ]
        for (name, ext) in names {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: ext))
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("swarmbar-remote-bridge-v1"), "\(name) has no marker")
            #expect(text.contains("--unix-socket") || text.contains("socketPath"), "\(name)")
            #expect(text.contains(".swarmbar/hook.sock"), "\(name)")
            #expect(!text.contains("127.0.0.1"), "\(name) reaches for loopback")
            #expect(!text.contains("X-SwarmBar-Token"), "\(name) sends a token")
        }
    }
}
