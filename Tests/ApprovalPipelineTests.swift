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
