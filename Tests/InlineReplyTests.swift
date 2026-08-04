import Foundation
import Testing
@testable import SwarmBar

@MainActor
struct AppleScriptLiteralTests {
    @Test func escapesDoubleQuotes() {
        #expect(AppleScriptLiteral.escape("say \"hi\"") == "say \\\"hi\\\"")
    }

    @Test func escapesBackslashes() {
        #expect(AppleScriptLiteral.escape("a\\b") == "a\\\\b")
    }

    @Test func escapesBackslashBeforeQuote() {
        // Order matters: escaping the quote first would then double-escape
        // the backslash this step adds.
        #expect(AppleScriptLiteral.escape("\\\"") == "\\\\\\\"")
    }

    @Test func leavesOrdinaryTextAlone() {
        #expect(AppleScriptLiteral.escape("please retry the migration") ==
                "please retry the migration")
        #expect(AppleScriptLiteral.escape("") == "")
        #expect(AppleScriptLiteral.escape("3") == "3")
    }

    @Test func singleLineExpressionIsOneLiteral() {
        #expect(AppleScriptLiteral.expression("hello") == "\"hello\"")
    }

    @Test func multiLineExpressionJoinsWithLinefeed() {
        let out = AppleScriptLiteral.expression("first\nsecond")
        #expect(out == "\"first\" & linefeed & \"second\"")
    }

    @Test func multiLineExpressionEscapesEachLine() {
        let out = AppleScriptLiteral.expression("say \"a\"\nthen \"b\"")
        #expect(out.contains("\\\"a\\\""))
        #expect(out.contains("linefeed"))
    }

    @Test func blankLinesSurvive() {
        let out = AppleScriptLiteral.expression("a\n\nb")
        #expect(out == "\"a\" & linefeed & \"\" & linefeed & \"b\"")
    }
}

@MainActor
struct PasteScriptTests {
    @Test func wrapsPayloadInBracketedPasteMarkers() {
        let script = TerminalFocuser.pasteScript(tty: "ttys004", text: "hello")
        #expect(script.contains("[200~"))
        #expect(script.contains("[201~"))
    }

    @Test func targetsTheGivenTty() {
        let script = TerminalFocuser.pasteScript(tty: "ttys009", text: "hello")
        #expect(script.contains("if tty of s is \"/dev/ttys009\""))
    }

    @Test func containsNoSubmit() {
        // The whole point of the design: pasting and pressing Enter are
        // separate steps so the paste can be verified in between. A bare
        // `write text ""` is how this codebase sends a newline.
        let script = TerminalFocuser.pasteScript(tty: "ttys004", text: "a\nb")
        #expect(!script.contains("write text \"\"\n"))
        #expect(!script.contains("tell s to write text \"\""))
    }

    @Test func multiLineTextUsesLinefeedNotRawNewlines() {
        let script = TerminalFocuser.pasteScript(tty: "ttys004", text: "first\nsecond")
        #expect(script.contains("\"first\" & linefeed & \"second\""))
    }

    @Test func quotesInReplyCannotEndTheLiteral() {
        let script = TerminalFocuser.pasteScript(tty: "ttys004", text: "use \"strict\" mode")
        #expect(script.contains("\\\"strict\\\""))
    }

    @Test func writesExactlyOnce() {
        let script = TerminalFocuser.pasteScript(tty: "ttys004", text: "a\nb\nc")
        #expect(script.components(separatedBy: "write text").count - 1 == 1)
    }
}

@MainActor
struct KeyScriptEscapingRetrofitTests {
    @Test func digitsAndTokensAreUnchangedByTheRetrofit() {
        // The approval paths only ever send digits and fixed tokens, none of
        // which contain characters needing escapes. Adding escaping must
        // therefore leave their emitted scripts byte-identical.
        #expect(TerminalFocuser.keyScript(tty: "ttys004", keys: ["3"])
            .contains("write text \"3\" newline NO"))
        #expect(TerminalFocuser.keyScript(tty: "ttys004", keys: ["y"])
            .contains("write text \"y\" newline NO"))
        #expect(TerminalFocuser.keyScript(tty: "ttys004", keys: ["ESC"])
            .contains("write text (character id 27) newline NO"))
        #expect(TerminalFocuser.keyScript(tty: "ttys004", keys: ["DOWN"])
            .contains("[B"))
    }

    @Test func aKeyCarryingAQuoteCannotEndTheLiteral() {
        let script = TerminalFocuser.keyScript(tty: "ttys004", keys: ["\"; do harm"])
        #expect(script.contains("\\\"; do harm"))
    }
}

@MainActor
struct VerificationProbeTests {
    @Test func usesTheLastNonEmptyLine() {
        #expect(TerminalFocuser.verificationProbe(for: "first\nsecond") == "second")
    }

    @Test func ignoresTrailingBlankLines() {
        #expect(TerminalFocuser.verificationProbe(for: "only\n\n  \n") == "only")
    }

    @Test func boundsTheProbeLength() {
        let long = String(repeating: "x", count: 200)
        let probe = TerminalFocuser.verificationProbe(for: long)
        #expect(probe?.count == 24)
    }

    @Test func emptyTextHasNoProbe() {
        #expect(TerminalFocuser.verificationProbe(for: "") == nil)
        #expect(TerminalFocuser.verificationProbe(for: "   \n  ") == nil)
    }
}

@MainActor
struct ReplyEligibilityTests {
    @Test func finishedTurnsAcceptReplies() {
        #expect(SessionStore.canReceiveReply(.waitingInput(prompt: "which one?")))
        #expect(SessionStore.canReceiveReply(.done(summary: "Merged")))
    }

    @Test func busyOrGoneSessionsDoNot() {
        // Typing into a working TUI lands in a redrawing composer; an idle
        // session may have exited with its tty reassigned.
        #expect(!SessionStore.canReceiveReply(.working(activity: "Editing")))
        #expect(!SessionStore.canReceiveReply(.runningTool(activity: "Running swift build")))
        #expect(!SessionStore.canReceiveReply(.idle))
        // An approval is answered with Approve and Deny, not prose.
        #expect(!SessionStore.canReceiveReply(.waitingApproval(command: "rm -rf /tmp/x")))
    }
}

@MainActor
struct SendReplyGuardTests {
    private func session(_ status: SessionStatus) -> AgentSession {
        AgentSession(
            tool: .claudeCode, projectName: "proj",
            projectPath: URL(fileURLWithPath: "/tmp"), status: status)
    }

    @Test func refusesEmptyText() {
        let store = SessionStore()
        let s = session(.waitingInput(prompt: "?"))
        store.upsert(s)
        var result: SessionStore.ReplyResult?
        store.sendReply(s, text: "   \n  ") { result = $0 }
        #expect(result == .failed("Nothing to send."))
    }

    @Test func refusesAVanishedSession() {
        let store = SessionStore()
        let s = session(.waitingInput(prompt: "?"))
        var result: SessionStore.ReplyResult?
        store.sendReply(s, text: "hello") { result = $0 }
        #expect(result == .failed("That session is gone."))
    }

    @Test func refusesASessionThatStartedWorking() {
        let store = SessionStore()
        var s = session(.waitingInput(prompt: "?"))
        store.upsert(s)
        // The agent picked up again while the user was typing.
        s.status = .working(activity: "Editing")
        store.upsert(s)

        var result: SessionStore.ReplyResult?
        store.sendReply(s, text: "please also update the docs") { result = $0 }
        #expect(result == .failed("That session is busy now, so nothing was sent."))
        // Status untouched: nothing was delivered.
        #expect(store.sessions[0].status == .working(activity: "Editing"))
    }
}
