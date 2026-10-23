import Foundation
import Testing
@testable import SwarmBar

/// Records every request the supervisor makes of a host's helper and
/// answers each command with a scripted reply, so the keystroke path runs
/// end to end without ssh, tmux or a python process.
private actor FakeHelper: RemoteRequesting {
    private(set) var calls: [(command: String, arguments: [String: JSONValue])] = []
    private let replies: [String: String]

    init(replies: [String: String]) {
        self.replies = replies
    }

    func request(
        _ command: String, _ arguments: [String: JSONValue], timeout: Duration
    ) async throws -> Data {
        calls.append((command, arguments))
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
    }

    // MARK: - The supervisor

    private static let pane = #"{"socket":"/tmp/tmux-1000/default","id":"%3"}"#

    private static func snapshot(pid: Int, pane: String?) throws -> RemoteSnapshot {
        let paneField = pane.map { #","pane":\#($0)"# } ?? ""
        let json = """
        {"ok":true,"protocol":3,"stream":"s1","hostname":"devbox","system":"Linux","now":1,
         "homes":[],"files":[],"dirs":[],"omitted":[],"warnings":[],
         "processes":[{"pid":\(pid),"ppid":1,"user":"u","comm":"kimi","args":"kimi",
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

        init(approvalsOff: Set<AgentTool> = [], replies: [String: String] = [:]) {
            let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
            let localHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("remote-answer-local-\(UUID().uuidString)", isDirectory: true)
            let server = HookServer(store: store, localHome: localHome)
            store.approvalResponder = server
            // Nothing here may ever drive this Mac's terminal.
            store.localAnswerObserver = { _, _ in Issue.record("reached the local terminal path") }
            let registry = RemoteHostRegistry(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
            let mirrorRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("remote-answer-mirror-\(UUID().uuidString)", isDirectory: true)
            let helper = FakeHelper(replies: replies)
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
        rig.connection?.noteApplied(try Self.snapshot(pid: 4242, pane: Self.pane))
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
        rig.connection?.noteApplied(try Self.snapshot(pid: 4242, pane: nil))
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
        rig.connection?.noteApplied(try Self.snapshot(pid: 4242, pane: Self.pane))
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
        rig.connection?.noteApplied(try Self.snapshot(pid: 4242, pane: Self.pane))
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
        rig.connection?.noteApplied(try Self.snapshot(pid: 4242, pane: Self.pane))
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
    }

    @Test func sentKeysMoveTheRowOn() async throws {
        let rig = Rig(replies: [
            "capture": #"{"text":"1. Approve once\n2. Reject"}"#,
            "keys": #"{"sent":true}"#,
        ])
        rig.connection?.noteApplied(try Self.snapshot(pid: 4242, pane: Self.pane))
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

    @Test func terminalOnlyNoteNamesTheHost() {
        #expect(RemoteRowLabel.terminalOnlyNote(host: "devbox") == "Answer in the terminal on devbox")
    }
}
