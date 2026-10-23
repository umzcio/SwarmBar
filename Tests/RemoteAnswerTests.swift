import Foundation
import Testing
@testable import SwarmBar

/// Records every request the supervisor makes of a host's helper and
/// answers each command with a scripted reply, so the keystroke path runs
/// end to end without ssh, tmux or a python process.
private actor FakeHelper: RemoteRequesting {
    private(set) var calls: [(command: String, arguments: [String: JSONValue])] = []
    private let replies: [String: String]
    /// Holds every answer back this long, so a test can act while a
    /// request is still in flight.
    private let delay: Duration?

    init(replies: [String: String], delay: Duration? = nil) {
        self.replies = replies
        self.delay = delay
    }

    func request(
        _ command: String, _ arguments: [String: JSONValue], timeout: Duration
    ) async throws -> Data {
        calls.append((command, arguments))
        if let delay { try await Task.sleep(for: delay) }
        guard let reply = replies[command] else { throw SSHChannelError.timedOut }
        return Data(reply.utf8)
    }

    var commands: [String] { calls.map(\.command) }
}

/// The remote answer path: what is pressed, where, and when nothing is.
/// A wrong key here lands in somebody's live agent session on a server.
@MainActor
@Suite("Remote keystroke answers")
struct RemoteAnswerTests {
    // MARK: - The pure plan

    @Test func numberedPlanPressesTheReadDigit() {
        let screen = "1. Approve once\n2. Approve for session\n3. Reject"
        let command = RemoteAnswerPlan.command(
            route: .numberedSelector, screen: screen,
            choose: TuiPromptLayout.approveOnceOption(in:))
        #expect(command == RemoteKeyCommand(keys: ["1"], expect: ["Approve once"]))

        let deny = RemoteAnswerPlan.command(
            route: .numberedSelector, screen: screen,
            choose: TuiPromptLayout.rejectOption(in:))
        #expect(deny == RemoteKeyCommand(keys: ["3"], expect: ["Reject"]))
    }

    @Test func navigatePlanWalksFromCursor() {
        let screen = "> 1. Approve\n  2. Deny"
        let command = RemoteAnswerPlan.command(
            route: .navigateSelector, screen: screen,
            choose: TuiPromptLayout.rejectOption(in:))
        #expect(command == RemoteKeyCommand(keys: ["DOWN", "\n"], expect: ["Deny", "> 1. Approve"]))

        // Already on the option: no arrows, just the submit, and the marked
        // line is still what is confirmed.
        let approve = RemoteAnswerPlan.command(
            route: .navigateSelector, screen: screen,
            choose: TuiPromptLayout.approveOnceOption(in:))
        #expect(approve == RemoteKeyCommand(keys: ["\n"], expect: ["Approve", "> 1. Approve"]))
    }

    @Test func fixedKeysPassThrough() {
        let codex = RemoteAnswerPlan.command(
            route: .keys(TuiAnswer.codexDeny), screen: nil,
            choose: TuiPromptLayout.rejectOption(in:))
        #expect(codex == RemoteKeyCommand(keys: ["ESC"], expect: []))
    }

    @Test func grokKeysPassThroughUnchanged() {
        let approve = RemoteAnswerPlan.command(
            route: ApprovalRouter.route(tool: .grokBuild, allow: true, in: .init()),
            screen: nil, choose: TuiPromptLayout.approveOnceOption(in:))
        #expect(approve == RemoteKeyCommand(keys: TuiAnswer.grokApprove, expect: []))
        #expect(approve?.keys.contains { Int($0) != nil } == false)

        let deny = RemoteAnswerPlan.command(
            route: ApprovalRouter.route(tool: .grokBuild, allow: false, in: .init()),
            screen: nil, choose: TuiPromptLayout.rejectOption(in:))
        #expect(deny == RemoteKeyCommand(keys: TuiAnswer.grokDeny, expect: []))
    }

    @Test func unreadableScreenGivesNil() {
        let approve = TuiPromptLayout.approveOnceOption(in:)
        // No screen at all.
        #expect(RemoteAnswerPlan.command(route: .numberedSelector, screen: nil, choose: approve) == nil)
        #expect(RemoteAnswerPlan.command(route: .navigateSelector, screen: nil, choose: approve) == nil)
        // A screen with no selector on it.
        let prose = "Thinking about the change\nstill working"
        #expect(RemoteAnswerPlan.command(route: .numberedSelector, screen: prose, choose: approve) == nil)
        // A selector with no marked cursor cannot be walked.
        let unmarked = "1. Approve\n2. Deny"
        #expect(RemoteAnswerPlan.command(route: .navigateSelector, screen: unmarked, choose: approve) == nil)
        // Routes that never press anything.
        #expect(RemoteAnswerPlan.command(route: .focusTerminal, screen: unmarked, choose: approve) == nil)
        #expect(RemoteAnswerPlan.command(route: .mockTransition, screen: unmarked, choose: approve) == nil)
    }

    @Test func repliesDecodeStrictly() {
        #expect(RemoteAnswerPlan.screen(fromCapture: Data(#"{"text":"1. Yes","id":3}"#.utf8)) == "1. Yes")
        #expect(RemoteAnswerPlan.screen(fromCapture: Data(#"{"ok":false,"error":"bad pane","id":3}"#.utf8)) == nil)
        #expect(RemoteAnswerPlan.screen(fromCapture: Data("not json".utf8)) == nil)

        #expect(RemoteAnswerPlan.keysOutcome(from: Data(#"{"sent":true,"id":4}"#.utf8)) == .sent)
        #expect(RemoteAnswerPlan.keysOutcome(from: Data(#"{"sent":false,"reason":"changed","id":4}"#.utf8))
            == .notSent("changed"))
        #expect(RemoteAnswerPlan.keysOutcome(from: Data(#"{"ok":false,"error":"bad pane","id":4}"#.utf8))
            == .notSent("bad pane"))
        #expect(RemoteAnswerPlan.keysOutcome(from: Data("garbage".utf8)) == .notSent("unreadable reply"))
        // A partial send says how many keys landed, which is what anyone
        // reading the log needs to know about the pane's state.
        #expect(RemoteAnswerPlan.keysOutcome(
            from: Data(#"{"sent":false,"reason":"send failed","sent_count":1}"#.utf8))
            == .notSent("send failed (sent_count 1)"))
    }

    /// Grok's fixed sequence clamps to the bottom and submits. At a bare
    /// shell that is a history recall and Enter, so remotely it is only
    /// sent where a selector is actually drawn.
    @Test func grokKeysNeedASelectorOnScreen() {
        let route = ApprovalRouter.route(tool: .grokBuild, allow: false, in: .init())
        #expect(RemoteAnswerPlan.needsScreen(tool: .grokBuild, route: route))
        let choose = TuiPromptLayout.rejectOption(in:)
        #expect(RemoteAnswerPlan.command(tool: .grokBuild, route: route, screen: nil, choose: choose) == nil)
        #expect(RemoteAnswerPlan.command(
            tool: .grokBuild, route: route, screen: "u@devbox:~/proj$ ", choose: choose) == nil)
        // One numbered line is prose, not a selector.
        #expect(RemoteAnswerPlan.command(
            tool: .grokBuild, route: route, screen: "1. Yes\nthat was it", choose: choose) == nil)

        let screen = "Allow write?\n> 1. Yes\n  2. Yes, always\n  3. No"
        let command = RemoteAnswerPlan.command(tool: .grokBuild, route: route, screen: screen, choose: choose)
        #expect(command?.keys == TuiAnswer.grokDeny)
        #expect(command?.expect == ["Yes", "Yes, always", "No"])

        // Codex's hotkeys are harmless at a shell and keep their plain path.
        let codex = ApprovalRouter.route(tool: .codex, allow: true, in: .init())
        #expect(!RemoteAnswerPlan.needsScreen(tool: .codex, route: codex))
        #expect(RemoteAnswerPlan.command(tool: .codex, route: codex, screen: nil, choose: choose)
            == RemoteKeyCommand(keys: ["y"], expect: []))
    }

    // MARK: - The supervisor

    private static let pane = #"{"socket":"/tmp/tmux-1000/default","id":"%3"}"#

    private static func snapshot(pid: Int, pane: String?, comm: String = "kimi") throws -> RemoteSnapshot {
        let paneField = pane.map { #","pane":\#($0)"# } ?? ""
        let json = """
        {"ok":true,"protocol":3,"stream":"s1","hostname":"devbox","system":"Linux","now":1,
         "homes":[],"files":[],"dirs":[],"omitted":[],"warnings":[],
         "processes":[{"pid":\(pid),"ppid":1,"user":"u","comm":"\(comm)","args":"\(comm)",
                       "cwd":"/home/u/proj","tty":"pts/1"\(paneField),"open":[]}],
         "processes_failed":false}
        """
        return try RemoteSnapshot.decode(Data(json.utf8))
    }

    @MainActor private final class Rig {
        let store: SessionStore
        let registry: RemoteHostRegistry
        let server: HookServer
        let supervisor: RemoteMonitorSupervisor
        let helper: FakeHelper
        let host: RemoteHost

        var connection: RemoteHostConnection? { supervisor.connection(forHostID: host.id) }

        /// A snapshot applied in full by a poll that also found the host
        /// reachable, which is what a keystroke answer needs both of.
        func land(_ snapshot: RemoteSnapshot) {
            connection?.noteHelperCurrent(true)
            connection?.noteApplied(snapshot)
            store.noteRemoteReachability(host: "devbox", .reachable)
        }

        init(
            approvalsOff: Set<AgentTool> = [], replies: [String: String] = [:],
            delay: Duration? = nil, remoteHold: Duration = .seconds(350)
        ) {
            let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
            let localHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("remote-answer-local-\(UUID().uuidString)", isDirectory: true)
            let server = HookServer(store: store, remoteDecisionHold: remoteHold, localHome: localHome)
            store.approvalResponder = server
            // Nothing here may ever drive this Mac's terminal.
            store.localAnswerObserver = { _, _ in Issue.record("reached the local terminal path") }
            let registry = RemoteHostRegistry(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
            let mirrorRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("remote-answer-mirror-\(UUID().uuidString)", isDirectory: true)
            let helper = FakeHelper(replies: replies, delay: delay)
            let supervisor = RemoteMonitorSupervisor(
                store: store, registry: registry,
                factory: { host in
                    // Never started: the fake below answers in its place.
                    let connection = RemoteHostConnection(
                        host: host,
                        channel: SSHChannel(launch: .local(python: "/usr/bin/false", script: "", homes: [])),
                        mirror: RemoteMirror(root: mirrorRoot))
                    return (IdleMonitor(), connection)
                },
                hookServer: server)
            supervisor.requester = { _ in helper }
            supervisor.keystrokeToggles = { (grok: true, antigravity: true) }
            store.remoteActions = supervisor
            let host = RemoteHost(alias: "devbox", approvalsOff: approvalsOff)
            registry.upsert(host)
            supervisor.reconcile()
            self.store = store
            self.registry = registry
            self.server = server
            self.supervisor = supervisor
            self.helper = helper
            self.host = host
        }
    }

    private struct IdleMonitor: SessionMonitor {
        func start(into store: SessionStore) async {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func kimi(pid: pid_t? = 4242) -> AgentSession {
        AgentSession(
            tool: .kimiCode, projectName: "proj",
            projectPath: URL(fileURLWithPath: "/home/u/proj"),
            status: .waitingApproval(command: "rm -rf build"), pid: pid, host: "devbox")
    }

    @Test func kimiWithAPaneTakesKeystrokes() async throws {
        let rig = Rig()
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        #expect(rig.supervisor.answerability(for: kimi()) == .keystrokes)
        // A session whose pid is unknown cannot be matched to a pane.
        #expect(rig.supervisor.answerability(for: kimi(pid: nil)) == .terminalOnly)
        // Nor can one whose pid is not in the snapshot.
        #expect(rig.supervisor.answerability(for: kimi(pid: 7)) == .terminalOnly)
    }

    @Test func noPaneMeansTerminalOnly() async throws {
        let rig = Rig(replies: [
            "capture": #"{"text":"1. Approve once\n2. Reject"}"#,
            "keys": #"{"sent":true}"#,
        ])
        rig.land(try Self.snapshot(pid: 4242, pane: nil))
        let session = kimi()
        rig.store.upsert(session)
        #expect(rig.supervisor.answerability(for: session) == .terminalOnly)
        #expect(rig.store.remoteAnswerability(for: session) == .terminalOnly)

        let sent = await rig.supervisor.performAnswer(session, allow: true)
        #expect(!sent)
        #expect(await rig.helper.commands.isEmpty)
        #expect(rig.store.sessions.first?.status == .waitingApproval(command: "rm -rf build"))
    }

    @Test func approvalsOffMeansTerminalOnly() async throws {
        let rig = Rig(approvalsOff: [.kimiCode], replies: ["keys": #"{"sent":true}"#])
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        #expect(rig.supervisor.answerability(for: kimi()) == .terminalOnly)
        #expect(await rig.supervisor.performAnswer(kimi(), allow: true) == false)
        #expect(await rig.helper.commands.isEmpty)
    }

    @Test func claudeIsHeldOnlyWhileHolding() async throws {
        let rig = Rig()
        let mirrorRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-answer-hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
        let mirror = RemoteMirror(root: mirrorRoot)
        let raw = UUID().uuidString
        let origin = RemoteHookOrigin(
            hostID: rig.host.id, hostName: "devbox", home: "/home/u",
            mirrorHome: mirror.local("/home/u"), peer: ["curl", "bash", "claude"], approvalsOff: [])
        rig.server.handleRemote(
            event: "PermissionRequest",
            body: ["session_id": raw, "tool_name": "Bash",
                   "tool_input": ["command": "git push"], "cwd": "/home/u/proj"],
            accountLabel: nil, origin: origin, rid: "r1", held: true) { _, _ in }
        let row = try #require(rig.store.sessions.first)
        #expect(row.tool == .claudeCode)
        #expect(rig.supervisor.answerability(for: row) == .held)

        // The hold ends somewhere else, and the view's observable signal
        // moves with it, so the row switches to the terminal note.
        let before = rig.store.remoteHoldRevision
        rig.server.cancelRemote(rid: "r1")
        #expect(rig.store.remoteHoldRevision != before)
        #expect(rig.supervisor.answerability(for: row) == .terminalOnly)

        // A Claude row nothing holds is never answered by keystrokes, even
        // with a pane.
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        let unheld = AgentSession(
            tool: .claudeCode, projectName: "proj", projectPath: URL(fileURLWithPath: "/home/u/proj"),
            status: .waitingApproval(command: "git push"), pid: 4242, host: "devbox")
        #expect(rig.supervisor.answerability(for: unheld) == .terminalOnly)
        #expect(await rig.supervisor.performAnswer(unheld, allow: true) == false)
        #expect(await rig.helper.commands.isEmpty)
    }

    @Test func refusedKeysLeaveTheRowAlone() async throws {
        let rig = Rig(replies: [
            "capture": #"{"text":"Run it?\n1. Approve once\n2. Approve for session\n3. Reject"}"#,
            "keys": #"{"sent":false,"reason":"changed"}"#,
        ])
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        let session = kimi()
        rig.store.upsert(session)

        let sent = await rig.supervisor.performAnswer(session, allow: true)
        #expect(!sent)
        #expect(rig.store.sessions.first?.status == .waitingApproval(command: "rm -rf build"))

        // The keys went to the session's own pane, with the digit read off
        // the screen and its label for the helper to re-confirm.
        let calls = await rig.helper.calls
        #expect(calls.map(\.command) == ["capture", "keys"])
        let paneValue: JSONValue = .object(["socket": .string("/tmp/tmux-1000/default"), "id": .string("%3")])
        #expect(calls[0].arguments == ["pane": paneValue])
        #expect(calls[1].arguments["pane"] == paneValue)
        #expect(calls[1].arguments["keys"] == .array([.string("1")]))
        #expect(calls[1].arguments["expect"] == .array([.string("Approve once")]))
        // And with the process it was meant for, so the helper can refuse
        // if that pid is gone, is another agent, or has left the pane.
        #expect(calls[1].arguments["pid"] == .int(4242))
        #expect(calls[1].arguments["comm"] == .string("kimi"))
    }

    // MARK: - Gaps, gates and the remaining routes

    @Test func unreachableHostSendsNothing() async throws {
        let rig = Rig(replies: ["capture": #"{"text":"1. Approve once\n2. Reject"}"#, "keys": #"{"sent":true}"#])
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        let session = kimi()
        rig.store.upsert(session)
        #expect(rig.supervisor.answerability(for: session) == .keystrokes)

        // The host goes dark. The snapshot is still held, but its pane map
        // is from before the gap, and a request would start ssh again.
        rig.store.noteRemoteReachability(host: "devbox", .unreachable("down"))
        #expect(rig.supervisor.answerability(for: session) == .terminalOnly)
        #expect(rig.store.remoteAnswerability(for: session) == .terminalOnly)
        #expect(await rig.supervisor.performAnswer(session, allow: true) == false)
        #expect(await rig.helper.commands.isEmpty)

        // Reachable again but with no snapshot since the gap: still nothing.
        rig.connection?.noteLost()
        rig.store.noteRemoteReachability(host: "devbox", .reachable)
        #expect(rig.supervisor.answerability(for: session) == .terminalOnly)
        #expect(await rig.supervisor.performAnswer(session, allow: true) == false)
        #expect(await rig.helper.commands.isEmpty)

        // A fresh snapshot lands and the row is answerable again.
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        #expect(rig.supervisor.answerability(for: session) == .keystrokes)
    }

    /// A host can read reachable while an out-of-date helper still runs
    /// (a push that failed for a reason other than sudo, or the minute
    /// before the next push). That helper ignores pid and comm, so keys
    /// would go unconfirmed by them.
    @Test func staleHelperSendsNoKeys() async throws {
        let rig = Rig(replies: ["capture": #"{"text":"1. Approve once\n2. Reject"}"#, "keys": #"{"sent":true}"#])
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        let session = kimi()
        rig.store.upsert(session)
        let connection = try #require(rig.connection)

        let before = rig.store.remotePaneRevision
        #expect(connection.noteHelperCurrent(false))
        #expect(!connection.noteHelperCurrent(false))
        rig.store.noteRemotePanesChanged()
        #expect(rig.store.remotePaneRevision != before)
        #expect(rig.store.remoteReachability["devbox"] == .reachable)
        #expect(rig.supervisor.answerability(for: session) == .terminalOnly)
        #expect(await rig.supervisor.performAnswer(session, allow: true) == false)
        #expect(await rig.helper.commands.isEmpty)

        // A gap makes the helper unknown again, as well as the panes.
        #expect(connection.noteHelperCurrent(true))
        connection.noteLost()
        #expect(!connection.helperIsCurrent)
    }

    @Test func helperExitForgetsThePanes() async throws {
        let rig = Rig()
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        let connection = try #require(rig.connection)
        var told = 0
        let relay = RemoteHookRelay(
            connection: connection, hookServer: rig.server, onHelperExited: { told += 1 })
        relay.handle(HelperEvent(name: HelperEvent.helperExited, payload: Data(), generation: 1))
        #expect(connection.lastSnapshot == nil)
        #expect(told == 1)
        #expect(rig.supervisor.answerability(for: kimi()) == .terminalOnly)
    }

    @Test func paneMapChangesAreReported() throws {
        let rig = Rig()
        let connection = try #require(rig.connection)
        #expect(connection.noteApplied(try Self.snapshot(pid: 4242, pane: Self.pane)))
        #expect(!connection.noteApplied(try Self.snapshot(pid: 4242, pane: Self.pane)))
        #expect(connection.noteApplied(try Self.snapshot(pid: 4242, pane: nil)))
        #expect(connection.noteApplied(try Self.snapshot(pid: 5000, pane: Self.pane)))
        #expect(connection.noteLost())
        #expect(!connection.noteLost())

        let before = rig.store.remotePaneRevision
        rig.store.noteRemotePanesChanged()
        #expect(rig.store.remotePaneRevision != before)
    }

    @Test func remoteGrokCapturesFirstAndNeedsASelector() async throws {
        let shell = Rig(replies: ["capture": #"{"text":"u@devbox:~/proj$ "}"#, "keys": #"{"sent":true}"#])
        shell.land(try Self.snapshot(pid: 4242, pane: Self.pane, comm: "grok"))
        let grok = AgentSession(
            tool: .grokBuild, projectName: "proj", projectPath: URL(fileURLWithPath: "/home/u/proj"),
            status: .waitingApproval(command: "write a.txt"), pid: 4242, host: "devbox")
        #expect(await shell.supervisor.performAnswer(grok, allow: true) == false)
        #expect(await shell.helper.commands == ["capture"])

        let prompt = Rig(replies: [
            "capture": #"{"text":"Allow write?\n> 1. Yes\n  2. Yes, always\n  3. No"}"#,
            "keys": #"{"sent":true}"#,
        ])
        prompt.land(try Self.snapshot(pid: 4242, pane: Self.pane, comm: "grok"))
        #expect(await prompt.supervisor.performAnswer(grok, allow: true))
        let calls = await prompt.helper.calls
        #expect(calls.map(\.command) == ["capture", "keys"])
        #expect(calls[1].arguments["keys"] == .array(TuiAnswer.grokApprove.map(JSONValue.string)))
        #expect(calls[1].arguments["comm"] == .string("grok"))
    }

    @Test func remoteCodexSendsItsHotkeyWithoutACapture() async throws {
        let rig = Rig(replies: ["keys": #"{"sent":true}"#])
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane, comm: "codex"))
        let codex = AgentSession(
            tool: .codex, projectName: "proj", projectPath: URL(fileURLWithPath: "/home/u/proj"),
            status: .waitingApproval(command: "make"), pid: 4242, host: "devbox")
        #expect(await rig.supervisor.performAnswer(codex, allow: true))
        let calls = await rig.helper.calls
        #expect(calls.map(\.command) == ["keys"])
        #expect(calls[0].arguments["keys"] == .array([.string("y")]))
        #expect(calls[0].arguments["expect"] == .array([]))
    }

    @Test func remoteAntigravityWalksByLabel() async throws {
        let rig = Rig(replies: ["capture": #"{"text":"Allow creation of this file?\n> 1. Approve\n  2. Deny"}"#,
                                "keys": #"{"sent":true}"#])
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane, comm: "agy"))
        let agy = AgentSession(
            tool: .antigravity, projectName: "proj", projectPath: URL(fileURLWithPath: "/home/u/proj"),
            status: .waitingApproval(command: "write a.txt"), pid: 4242, host: "devbox")
        rig.store.upsert(agy)
        #expect(await rig.supervisor.performAnswer(agy, allow: false))
        let calls = await rig.helper.calls
        #expect(calls.map(\.command) == ["capture", "keys"])
        #expect(calls[1].arguments["keys"] == .array([.string("DOWN"), .string("\n")]))
        #expect(calls[1].arguments["expect"] == .array([.string("Deny"), .string("> 1. Approve")]))
        #expect(calls[1].arguments["pid"] == .int(4242))
        #expect(calls[1].arguments["comm"] == .string("agy"))
        #expect(rig.store.sessions.first?.status == .working(activity: "Rethinking after deny…"))
    }

    @Test func keystrokeTogglesOffMeanTerminalOnly() async throws {
        let rig = Rig(replies: ["keys": #"{"sent":true}"#])
        rig.supervisor.keystrokeToggles = { (grok: false, antigravity: false) }
        for (tool, comm) in [(AgentTool.grokBuild, "grok"), (.antigravity, "agy")] {
            rig.land(try Self.snapshot(pid: 4242, pane: Self.pane, comm: comm))
            let session = AgentSession(
                tool: tool, projectName: "proj", projectPath: URL(fileURLWithPath: "/home/u/proj"),
                status: .waitingApproval(command: "x"), pid: 4242, host: "devbox")
            #expect(rig.supervisor.answerability(for: session) == .terminalOnly)
            #expect(await rig.supervisor.performAnswer(session, allow: true) == false)
        }
        #expect(await rig.helper.commands.isEmpty)
    }

    @Test func captureFailureSendsNothing() async throws {
        let refused = Rig(replies: ["capture": #"{"ok":false,"error":"capture failed"}"#, "keys": #"{"sent":true}"#])
        refused.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        refused.store.upsert(kimi())
        #expect(await refused.supervisor.performAnswer(kimi(), allow: true) == false)
        #expect(await refused.helper.commands == ["capture"])

        // No answer at all: the fake throws, as a timed out request does.
        let silent = Rig(replies: ["keys": #"{"sent":true}"#])
        silent.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        #expect(await silent.supervisor.performAnswer(kimi(), allow: true) == false)
        #expect(await silent.helper.commands == ["capture"])
    }

    @Test func aSecondClickWhileAnsweringSendsNothing() async throws {
        let rig = Rig(replies: ["capture": #"{"text":"1. Approve once\n2. Reject"}"#, "keys": #"{"sent":true}"#],
                      delay: .milliseconds(200))
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        let session = kimi()
        rig.store.upsert(session)
        let first = Task { await rig.supervisor.performAnswer(session, allow: true) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !rig.supervisor.answering.contains(session.id) && ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await rig.supervisor.performAnswer(session, allow: false) == false)
        #expect(await first.value)
        #expect(await rig.helper.commands == ["capture", "keys"])
        #expect(rig.supervisor.answering.isEmpty)
    }

    @Test func holdExpiryRedrawsTheRow() async throws {
        let rig = Rig(remoteHold: .milliseconds(50))
        let mirrorRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-answer-expiry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
        let mirror = RemoteMirror(root: mirrorRoot)
        let origin = RemoteHookOrigin(
            hostID: rig.host.id, hostName: "devbox", home: "/home/u",
            mirrorHome: mirror.local("/home/u"), peer: ["curl", "bash", "claude"], approvalsOff: [])
        rig.server.handleRemote(
            event: "PermissionRequest",
            body: ["session_id": UUID().uuidString, "tool_name": "Bash",
                   "tool_input": ["command": "git push"], "cwd": "/home/u/proj"],
            accountLabel: nil, origin: origin, rid: "r9", held: true) { _, _ in }
        let row = try #require(rig.store.sessions.first)
        #expect(rig.supervisor.answerability(for: row) == .held)
        let before = rig.store.remoteHoldRevision
        let deadline = ContinuousClock.now + .seconds(2)
        while rig.server.isHolding(sessionID: row.id) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The row keeps its prompt, so only the revision can redraw it.
        #expect(rig.store.sessions.first?.status == row.status)
        #expect(rig.store.remoteHoldRevision != before)
        #expect(rig.store.remoteAnswerability(for: row) == .terminalOnly)
    }

    @Test func sentKeysMoveTheRowOn() async throws {
        let rig = Rig(replies: [
            "capture": #"{"text":"1. Approve once\n2. Reject"}"#,
            "keys": #"{"sent":true}"#,
        ])
        rig.land(try Self.snapshot(pid: 4242, pane: Self.pane))
        let session = kimi()
        rig.store.upsert(session)
        #expect(await rig.supervisor.performAnswer(session, allow: false))
        #expect(rig.store.sessions.first?.status == .working(activity: "Rethinking after deny…"))
    }

    // MARK: - The store

    @MainActor private final class RecordingActions: RemoteActing {
        var answers: [(UUID, Bool)] = []
        func answerability(for session: AgentSession) -> RemoteAnswerability { .keystrokes }
        func answer(_ session: AgentSession, allow: Bool) { answers.append((session.id, allow)) }
        func reply(
            _ session: AgentSession, text: String,
            completion: @escaping @MainActor (SessionStore.ReplyResult) -> Void
        ) {}
    }

    @Test func remoteApproveNeverUsesLocalTerminal() {
        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        var routed: [AgentSession] = []
        store.localAnswerObserver = { session, _ in routed.append(session) }
        let actions = RecordingActions()
        store.remoteActions = actions

        let remote = kimi()
        store.upsert(remote)
        store.approve(remote)
        store.deny(remote)
        #expect(routed.isEmpty)
        #expect(actions.answers.map(\.0) == [remote.id, remote.id])
        #expect(actions.answers.map(\.1) == [true, false])

        // The local seam does see a local row, so the empty list above
        // means something.
        let local = AgentSession(
            tool: .kimiCode, projectName: "proj", projectPath: URL(fileURLWithPath: "/tmp"),
            status: .waitingApproval(command: "ls"))
        store.upsert(local)
        store.approve(local)
        #expect(routed.map(\.id) == [local.id])
        #expect(actions.answers.count == 2)
    }

    /// Keys confirmed for one prompt must not move a row that has since
    /// started asking about something else.
    @Test func aSentAnswerOnlyMovesTheSamePrompt() {
        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let answered = kimi()
        store.upsert(answered)
        var newer = answered
        newer.status = .waitingApproval(command: "git push --force")
        store.upsert(newer)
        store.noteRemoteAnswerSent(answered, allow: true)
        #expect(store.sessions.first?.status == .waitingApproval(command: "git push --force"))

        store.noteRemoteAnswerSent(newer, allow: true)
        #expect(store.sessions.first?.status == .runningTool(activity: "Running git"))
    }

    @Test func terminalOnlyNoteNamesTheHost() {
        #expect(RemoteRowLabel.terminalOnlyNote(host: "devbox") == "Answer in the terminal on devbox")
    }
}
