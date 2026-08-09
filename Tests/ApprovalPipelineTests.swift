import Foundation
import Testing
@testable import SwarmBar

@MainActor
struct TuiAnswerTests {
    @Test func grokApproveClampsThenStepsUp() {
        #expect(TuiAnswer.grokApprove.filter { $0 == "DOWN" }.count == 8)
        #expect(TuiAnswer.grokApprove.suffix(2) == ["UP", "\n"])
    }

    @Test func grokDenyClampsAndSubmitsTwice() {
        #expect(TuiAnswer.grokDeny.filter { $0 == "DOWN" }.count == 8)
        #expect(TuiAnswer.grokDeny.suffix(2) == ["\n", "\n"])
        // Deny must never step back up: that is how a deny once approved.
        #expect(!TuiAnswer.grokDeny.contains("UP"))
    }

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

/// The per-tool answer table. Every entry was settled by a live round, and
/// a wrong one does not fail loudly: it presses a key into a terminal.
/// While this lived as a run of branches inside SessionStore it could only
/// be exercised by driving a real terminal, so the thing most worth testing
/// was the one thing untestable.
@MainActor
struct ApprovalRouterTests {
    private let on = ApprovalRouter.Environment()

    // MARK: - Keystroke tools

    @Test func grokUsesItsNavigationSequences() {
        #expect(ApprovalRouter.route(tool: .grokBuild, allow: true, in: on)
            == .keys(TuiAnswer.grokApprove))
        #expect(ApprovalRouter.route(tool: .grokBuild, allow: false, in: on)
            == .keys(TuiAnswer.grokDeny))
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
            #expect(ApprovalRouter.route(tool: .antigravity, allow: allow, in: on)
                != .numberedSelector)
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
            == .keys(TuiAnswer.grokApprove))
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
            status: .waitingApproval(command: command))
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
