import Foundation
import Testing
@testable import SwarmBar

final class FixtureLocator {}

func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle(for: FixtureLocator.self)
        .url(forResource: name, withExtension: "jsonl"))
    return try String(contentsOf: url, encoding: .utf8)
}

@MainActor
struct ClaudeSessionParserTests {
    // Fixture timestamps are 2026-08-01T10:0x; "now" is moments later.
    let now = ClaudeSessionParser.date("2026-08-01T10:03:00.000Z")!

    @Test func runningToolFromTrailingToolUse() throws {
        let parsed = try #require(ClaudeSessionParser.parse(
            tail: fixture("claude-running-tool"), now: now))
        #expect(parsed.status == .runningTool(activity: "Running swift build 2>&1 | tail -5"))
        #expect(parsed.cwd == "/Users/zach/GitHub/demo")
    }

    @Test func waitingInputFromTrailingAssistantText() throws {
        let parsed = try #require(ClaudeSessionParser.parse(
            tail: fixture("claude-waiting-input"), now: now))
        #expect(parsed.status == .waitingInput(prompt: "The build passes now. Want me to also run the tests?"))
    }

    @Test func workingFromTrailingToolResult() throws {
        let parsed = try #require(ClaudeSessionParser.parse(
            tail: fixture("claude-working"), now: now))
        #expect(parsed.status == .working(activity: "Working through tool results…"))
    }

    @Test func staleSessionsGoIdle() throws {
        let muchLater = ClaudeSessionParser.date("2026-08-01T12:00:00.000Z")!
        let parsed = try #require(ClaudeSessionParser.parse(
            tail: fixture("claude-waiting-input"), now: muchLater))
        #expect(parsed.status == .idle)
    }

    @Test func metadataOnlyTailYieldsNothing() {
        let tail = """
        {"type":"last-prompt","leafUuid":"a","sessionId":"b"}
        {"type":"file-history-snapshot","messageId":"c"}
        """
        #expect(ClaudeSessionParser.parse(tail: tail, now: now) == nil)
    }

    @Test func decodeProjectDirFallback() {
        #expect(ClaudeSessionParser.decodeProjectDir("-Users-zach-GitHub-demo")
                == "/Users/zach/GitHub/demo")
        #expect(ClaudeSessionParser.decodeProjectDir("not-escaped") == nil)
    }
}

@MainActor
struct CodexSessionParserTests {
    let now = ClaudeSessionParser.date("2026-08-01T10:05:00.000Z")!

    @Test func runningToolFromFunctionCall() throws {
        let status = try #require(CodexSessionParser.parse(
            tail: fixture("codex-running"), now: now))
        #expect(status == .runningTool(activity: "Running exec_command"))
    }

    @Test func doneFromTaskComplete() throws {
        let status = try #require(CodexSessionParser.parse(
            tail: fixture("codex-done"), now: now))
        #expect(status == .done(summary: "Audit delivered with three findings."))
    }

    @Test func metaFromHead() throws {
        let meta = CodexSessionParser.meta(head: try fixture("codex-running"))
        #expect(meta.cwd == "/Users/zach/GitHub/demo")
        #expect(meta.sessionId == "0198a6b9-1111-7abc-9def-0123456789ab")
    }

    @Test func waitingApprovalFromUnansweredEscalatedCall() throws {
        let status = try #require(CodexSessionParser.parse(
            tail: fixture("codex-pending-approval"), now: now))
        #expect(status == .waitingApproval(
            command: "networksetup -listallnetworkservices && scutil --dns"))
    }

    @Test func answeredEscalatedCallIsNotPending() throws {
        let resolved = try fixture("codex-pending-approval") + """
        {"timestamp":"2026-08-01T10:04:30.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","id":"ctco_2","call_id":"call_escalated","output":[{"type":"input_text","text":"Rejected(\\"approval request aborted\\")"}]}}
        """
        #expect(CodexSessionParser.pendingApproval(tail: resolved) == nil)
        let status = try #require(CodexSessionParser.parse(tail: resolved, now: now))
        #expect(status == .working(activity: "Working through tool results…"))
    }

    @Test func sandboxedCallWithoutOutputIsNotAnApproval() {
        let tail = """
        {"timestamp":"2026-08-01T10:04:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_plain","name":"exec","input":"const r = await tools.exec_command({\\"cmd\\":\\"ls\\",\\"workdir\\":\\"/Users/zach\\"});"}}
        """
        #expect(CodexSessionParser.pendingApproval(tail: tail) == nil)
        #expect(CodexSessionParser.parse(tail: tail, now: now)
                == .runningTool(activity: "Running exec"))
    }
}

@MainActor
struct KimiWireParserTests {
    @Test func finishedPlainReportIsDone() throws {
        let status = try #require(KimiWireParser.parse(tail: fixture("kimi-wire")))
        #expect(status == .done(
            summary: "I can't run system commands to inspect your network settings right now."))
    }

    @Test func trailingCancelIsIdle() throws {
        let tail = try fixture("kimi-wire") + """
        {"type":"turn.prompt","input":[{"type":"text","text":"again"}],"origin":{"kind":"user"},"time":1785790084294}
        {"type":"turn.cancel","time":1785790085169}
        """
        #expect(KimiWireParser.parse(tail: tail) == .idle)
    }

    @Test func trailingToolCallIsRunningTool() {
        let tail = """
        {"type":"context.append_loop_event","event":{"type":"tool.call","toolCallId":"t1","name":"Bash","display":{"kind":"command","command":"swift build 2>&1"}}}
        """
        #expect(KimiWireParser.parse(tail: tail)
                == .runningTool(activity: "Running swift build 2>&1"))
    }

    @Test func trailingRequestIsWorking() {
        let tail = """
        {"type":"turn.prompt","input":[{"type":"text","text":"hi"}],"origin":{"kind":"user"}}
        {"type":"llm.request","kind":"loop","provider":"kimi"}
        """
        #expect(KimiWireParser.parse(tail: tail) == .working(activity: "Thinking…"))
    }

    @Test func configOnlyWireYieldsNothing() {
        let tail = """
        {"type":"metadata","recordVersion":1}
        {"type":"config.update","profileName":"agent"}
        """
        #expect(KimiWireParser.parse(tail: tail) == nil)
    }
}

@MainActor
struct TuiPromptLayoutTests {
    let kimiShellPrompt = """
      ▶ Run this command?

      cwd: /Users/zach
      $ ifconfig | grep -E "^(en|lo)" -A 5

      ▶ 1. Approve once
        2. Approve for this session
        3. Reject
        4. Reject with feedback

      ↑/↓ select · 1/2/3/4 choose · ↵ confirm
    """

    @Test func readsNumberedOptions() {
        let options = TuiPromptLayout.options(in: kimiShellPrompt)
        #expect(options.map(\.number) == [1, 2, 3, 4])
        #expect(options.first?.label == "Approve once")
    }

    @Test func picksOnceOnlyApproveAndPlainReject() {
        #expect(TuiPromptLayout.approveOnce(in: kimiShellPrompt) == 1)
        #expect(TuiPromptLayout.reject(in: kimiShellPrompt) == 3)
    }

    @Test func reorderedLayoutStillResolvesByLabel() {
        let screen = """
          1. Approve for this session
          2. Reject with feedback
          3. Approve once
          4. Reject
        """
        #expect(TuiPromptLayout.approveOnce(in: screen) == 3)
        #expect(TuiPromptLayout.reject(in: screen) == 4)
    }

    // MARK: - Arrow navigation

    /// Antigravity's prompt, copied off a real terminal. It advertises
    /// arrows and enter and says nothing about digits, so it is walked to
    /// rather than typed at.
    let antigravityPrompt = """
      ? Do you approve writing a file containing 'hello'?

      Question

      Question 1/1: Do you approve writing a file containing 'hello'?

      > 1. Approve
        2. Deny
        3. Write-in...

        ↑/↓ Navigate · enter Select · esc Skip
    """

    @Test func theCursorIsReadOffTheMarkedLine() {
        let selector = TuiPromptLayout.selector(in: antigravityPrompt)
        #expect(selector.options.map(\.label) == ["Approve", "Deny", "Write-in..."])
        #expect(selector.cursor == 1)
        #expect(selector.cursorLine == "> 1. Approve")
    }

    /// The whole point of reading the cursor: the distance is computed,
    /// not assumed. Deny is one down from Approve here, and would be a
    /// different move on a prompt that opened elsewhere.
    @Test func theMoveIsComputedFromWhereTheCursorActuallyIs() {
        #expect(TuiPromptLayout.reject(in: antigravityPrompt) == 2)
        let move = TuiPromptLayout.navigation(from: 1, to: 2)
        #expect(move?.key == "DOWN")
        #expect(move?.presses == 1)
    }

    /// Never more presses than the distance within the list, so a wrapping
    /// selector cannot come back around. Eight blind DOWNs on a four-item
    /// Kimi prompt landed on "Approve once" and approved a denied command.
    @Test func theMoveNeverOvershootsTheList() {
        #expect(TuiPromptLayout.navigation(from: 3, to: 1)?.key == "UP")
        #expect(TuiPromptLayout.navigation(from: 3, to: 1)?.presses == 2)
        #expect(TuiPromptLayout.navigation(from: 2, to: 2)?.presses == 0)
    }

    /// With no cursor drawn there is no distance to compute, and the
    /// caller falls back to focusing the terminal rather than guessing
    /// that the cursor starts at the top.
    @Test func anUnmarkedSelectorHasNoCursor() {
        let selector = TuiPromptLayout.selector(in: """
              1. Approve
              2. Deny
            """)
        #expect(selector.options.count == 2)
        #expect(selector.cursor == nil)
        #expect(selector.cursorLine == nil)
    }

    /// The marker the Kimi family draws is a different glyph, and it is
    /// read the same way, so this path is not Antigravity-only.
    @Test func theKimiCursorIsReadToo() {
        #expect(TuiPromptLayout.selector(in: kimiShellPrompt).cursor == 1)
    }

    @Test func latestBlockWins() {
        let screen = """
          1. Approve once
          2. Reject
          (older prompt above, answered)

          1. Yes, proceed
          2. Yes, and don't ask again
          3. No, tell the agent what to do differently
        """
        #expect(TuiPromptLayout.options(in: screen).count == 3)
        #expect(TuiPromptLayout.approveOnce(in: screen) == 1)
        #expect(TuiPromptLayout.reject(in: screen) == 3)
    }

    @Test func screenWithoutSelectorYieldsNothing() {
        let screen = "Here are your current macOS network settings:\n  IP address 10.0.0.1"
        #expect(TuiPromptLayout.options(in: screen).isEmpty)
        #expect(TuiPromptLayout.approveOnce(in: screen) == nil)
        #expect(TuiPromptLayout.reject(in: screen) == nil)
    }

    @Test func agentProseWithANumberedListIsNotASelector() {
        let screen = """
          Here is my plan:

          1. Read the config
          2. Patch the parser

          Anything else you want changed?
        """
        // A plan is a contiguous numbered run, so it parses as a block, but
        // it must not produce an approve or reject answer.
        #expect(TuiPromptLayout.approveOnce(in: screen) == nil)
        #expect(TuiPromptLayout.reject(in: screen) == nil)
    }

    @Test func aSingleNumberedLineIsNotASelector() {
        #expect(TuiPromptLayout.options(in: "  1. Approve once").isEmpty)
    }

    @Test func proseBreaksABlock() {
        let screen = """
          1. Approve once
          some explanatory prose here
          2. Reject
        """
        #expect(TuiPromptLayout.options(in: screen).isEmpty)
    }

    @Test func theBottomMostBlockWinsOverAnEarlierOne() {
        let screen = """
          1. Approve once
          2. Reject

          Older prompt above.

          1. Yes, proceed
          2. No, stop
        """
        let options = TuiPromptLayout.options(in: screen)
        #expect(options.count == 2)
        #expect(options.first?.label == "Yes, proceed")
        #expect(TuiPromptLayout.reject(in: screen) == 2)
    }

    @Test func rejectDoesNotMatchNotesOrNotNow() {
        let screen = """
          1. Approve once
          2. Note: this touches production
          3. Not now, ask me later
        """
        // None of these are a selector rejection.
        #expect(TuiPromptLayout.reject(in: screen) == nil)
    }

    @Test func optionHelpersCarryTheLabel() {
        #expect(TuiPromptLayout.approveOnceOption(in: kimiShellPrompt)?.label == "Approve once")
        #expect(TuiPromptLayout.rejectOption(in: kimiShellPrompt)?.number == 3)
    }
}

/// `lsof -F pn` output, parsed into "who holds which file".
///
/// Both of these fail silently when they are wrong. The Codex map is
/// looked up by "<uuid>.jsonl", so a suffix that does not match means
/// every Codex session reads as dead with nothing logged. Antigravity's
/// entire session-to-pid map comes through the other one, so a mistake
/// there makes Reply, Approve and Open in Terminal all aim at nothing.
@MainActor
struct LsofParsingTests {
    private let root = "/Users/zach/.codex/sessions"

    /// A p line owns the n lines that follow it, and lsof groups by
    /// process rather than repeating the pid.
    private var output: String {
        """
        p4242
        n/Users/zach/.codex/sessions/2026/08/08/rollout-2026-08-08T10-00-00-\
        aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl
        n/Users/zach/somewhere/else.jsonl
        p777
        n/Users/zach/.codex/sessions/2026/08/07/rollout-2026-08-07T09-00-00-\
        11111111-2222-3333-4444-555555555555.jsonl
        """
    }

    @Test func eachRolloutMapsToTheProcessHoldingIt() {
        let pids = TerminalFocuser.codexPids(inLsofOutput: output, sessionsRoot: root)
        #expect(pids["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"] == 4242)
        #expect(pids["11111111-2222-3333-4444-555555555555.jsonl"] == 777)
    }

    /// The key must be exactly what CodexMonitor looks up, which is
    /// "\(id.uuidString.lowercased()).jsonl" and nothing else. If this
    /// drifts, every Codex row silently reads as dead.
    @Test func theKeyIsTheLowercasedUUIDPlusExtensionAndNothingElse() {
        let id = UUID()
        let path = "\(root)/2026/08/08/rollout-2026-08-08T10-00-00-\(id.uuidString).jsonl"
        let pids = TerminalFocuser.codexPids(
            inLsofOutput: "p9\nn\(path)", sessionsRoot: root)
        #expect(pids == ["\(id.uuidString.lowercased()).jsonl": 9])
    }

    @Test func filesOutsideTheSessionsRootAreIgnored() {
        let pids = TerminalFocuser.codexPids(inLsofOutput: output, sessionsRoot: root)
        #expect(pids.count == 2)
    }

    @Test func nonRolloutFilesAndShortNamesAreIgnored() {
        let text = """
            p1
            n\(root)/2026/08/08/notes.jsonl
            n\(root)/2026/08/08/rollout-short.jsonl
            """
        #expect(TerminalFocuser.codexPids(inLsofOutput: text, sessionsRoot: root).isEmpty)
    }

    /// A path with no p line before it belongs to no process, and must not
    /// be attributed to whichever process happened to come later.
    @Test func aPathBeforeAnyProcessLineIsDropped() {
        let text = "n\(root)/2026/08/08/rollout-x-\(UUID().uuidString).jsonl\np5"
        #expect(TerminalFocuser.codexPids(inLsofOutput: text, sessionsRoot: root).isEmpty)
    }

    // MARK: - Held files

    @Test func heldFilesMapPathsToTheirHolder() {
        let text = """
            p88837
            n/Users/zach/.gemini/antigravity-cli/presence/abc-123.lock
            n/Users/zach/elsewhere/other.lock
            """
        let held = ProcessLiveness.heldFiles(
            inLsofOutput: text, directory: "/Users/zach/.gemini/antigravity-cli/presence")
        #expect(held == ["/Users/zach/.gemini/antigravity-cli/presence/abc-123.lock": 88837])
    }

    /// The directory is matched as a path prefix, so it must end at a
    /// boundary. Without that, "presence" would also match a sibling
    /// directory called "presence-old".
    @Test func aSiblingDirectoryWithASharedPrefixDoesNotMatch() {
        let text = "p1\nn/Users/zach/state/presence-old/abc.lock"
        #expect(ProcessLiveness.heldFiles(
            inLsofOutput: text, directory: "/Users/zach/state/presence").isEmpty)
    }

    @Test func aTrailingSlashOnTheDirectoryIsAccepted() {
        let text = "p1\nn/Users/zach/state/presence/abc.lock"
        #expect(ProcessLiveness.heldFiles(
            inLsofOutput: text, directory: "/Users/zach/state/presence/").count == 1)
    }

    @Test func emptyOutputIsNoProcesses() {
        #expect(TerminalFocuser.codexPids(inLsofOutput: "", sessionsRoot: root).isEmpty)
        #expect(ProcessLiveness.heldFiles(inLsofOutput: "", directory: "/x").isEmpty)
    }
}

/// Values interpolated into AppleScript source. Everything SwarmBar sends
/// to a terminal is built by string interpolation, and the labels come off
/// the terminal screen, which means the agent wrote them.
@MainActor
struct AppleScriptEscapingTests {
    @Test func quotesAndBackslashesAreEscaped() {
        #expect(AppleScriptLiteral.escape(#"say "hi""#) == #"say \"hi\""#)
        #expect(AppleScriptLiteral.escape(#"C:\path\"#) == #"C:\\path\\"#)
    }

    /// The failure the old quote-stripping caused. A label carrying a
    /// quote no longer matched the screen it was read from, so Approve
    /// silently degraded to opening a terminal window.
    @Test func anEscapedLabelStillMatchesTheScreenItCameFrom() {
        let label = #"Approve "once""#
        let escaped = AppleScriptLiteral.escape(label)
        // What AppleScript sees after it parses the literal is the label.
        #expect(escaped.replacingOccurrences(of: #"\""#, with: "\"") == label)
        #expect(escaped != label.replacingOccurrences(of: "\"", with: ""))
    }

    /// The other half: an odd number of trailing backslashes used to
    /// unbalance the string literal and break the whole script.
    @Test func aTrailingBackslashCannotEndTheLiteral() {
        let escaped = AppleScriptLiteral.escape(#"Approve \"#)
        #expect(escaped.hasSuffix(#"\\"#))
        // Every backslash in the result is part of a two-character escape,
        // so none of them can escape the closing quote.
        #expect(escaped.filter { $0 == "\\" }.count % 2 == 0)
    }

    @Test func multiLineTextIsJoinedWithLinefeed() {
        #expect(AppleScriptLiteral.expression("a\nb") == "\"a\" & linefeed & \"b\"")
        #expect(AppleScriptLiteral.expression("plain") == "\"plain\"")
        #expect(AppleScriptLiteral.expression("") == "\"\"")
    }
}

/// What the approval row's command slot says. It is the whole content of
/// an approval request, so a tool whose description falls back to its own
/// name tells the user nothing about what they are approving.
@MainActor
struct HookCommandDescriptionTests {
    @Test func bashShowsItsCommand() {
        #expect(HookServer.commandDescription([
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build"],
        ]) == "rm -rf build")
    }

    @Test func aFileToolNamesTheFile() {
        #expect(HookServer.commandDescription([
            "tool_name": "Write",
            "tool_input": ["file_path": "/tmp/proj/server.js"],
        ]) == "Write server.js")
    }

    /// The row used to read "$ AskUserQuestion", which names the mechanism
    /// and says nothing about what is being asked.
    @Test func aQuestionShowsTheQuestion() {
        #expect(HookServer.commandDescription([
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which database should we use?"]]],
        ]) == "Which database should we use?")
    }

    @Test func severalQuestionsShowTheFirstAndACount() {
        #expect(HookServer.commandDescription([
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [
                ["question": "Which database?"],
                ["question": "Which host?"],
                ["question": "Which region?"],
            ]],
        ]) == "Which database? (+2 more)")
    }

    /// Read by shape, not by tool name, so a renamed tool with the same
    /// input still reads properly.
    @Test func theQuestionIsFoundWithoutMatchingTheToolName() {
        #expect(HookServer.commandDescription([
            "tool_name": "AskTheHuman",
            "tool_input": ["questions": [["question": "Ship it?"]]],
        ]) == "Ship it?")
    }

    /// Anything without a question falls back to what it did before.
    @Test func anEmptyOrAbsentQuestionFallsBack() {
        #expect(HookServer.questionText(["questions": []]) == nil)
        #expect(HookServer.questionText(["questions": [["question": "   "]]]) == nil)
        #expect(HookServer.commandDescription([
            "tool_name": "Glob", "tool_input": ["pattern": "**/*.swift"],
        ]) == "Glob")
    }
}

@MainActor
struct HookRequestParsingTests {
    private func request(headers: String, body: String) -> Data {
        Data("POST /hook/PermissionRequest HTTP/1.1\r\n\(headers)\r\n\r\n\(body)".utf8)
    }

    @Test func parsesAWellFormedRequest() {
        let body = "{\"session_id\":\"abc\",\"cwd\":\"/tmp\"}"
        let data = request(headers: "Content-Length: \(body.utf8.count)", body: body)
        guard case .complete(let parsed) = HookServer.parseRequest(data) else {
            Issue.record("expected a complete parse"); return
        }
        #expect(parsed.path == "/hook/PermissionRequest")
        #expect(parsed.body["session_id"] as? String == "abc")
    }

    @Test func refusesNegativeContentLength() {
        let data = request(headers: "Content-Length: -1", body: "{}")
        guard case .malformed = HookServer.parseRequest(data) else {
            Issue.record("expected malformed"); return
        }
    }

    @Test func refusesNonNumericContentLength() {
        let data = request(headers: "Content-Length: banana", body: "{}")
        guard case .malformed = HookServer.parseRequest(data) else {
            Issue.record("expected malformed"); return
        }
    }

    @Test func refusesOversizedContentLength() {
        let data = request(headers: "Content-Length: 999999999", body: "{}")
        guard case .malformed = HookServer.parseRequest(data) else {
            Issue.record("expected malformed"); return
        }
    }

    @Test func refusesABodyThatIsNotJSON() {
        let body = "not json at all"
        let data = request(headers: "Content-Length: \(body.utf8.count)", body: body)
        guard case .malformed = HookServer.parseRequest(data) else {
            Issue.record("expected malformed"); return
        }
    }

    @Test func refusesNonPostVerbs() {
        let data = Data("GET /hook/Stop HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        guard case .malformed = HookServer.parseRequest(data) else {
            Issue.record("expected malformed"); return
        }
    }

    @Test func waitsForMoreBytesWhenTheBodyIsShort() {
        let data = request(headers: "Content-Length: 40", body: "{\"a\":1}")
        guard case .incomplete = HookServer.parseRequest(data) else {
            Issue.record("expected incomplete"); return
        }
    }

    @Test func waitsWhenHeadersAreNotYetTerminated() {
        guard case .incomplete = HookServer.parseRequest(Data("POST /hook/Stop HTTP/1.1\r\n".utf8)) else {
            Issue.record("expected incomplete"); return
        }
    }

    @Test func allowsAMissingContentLengthAsAnEmptyBody() {
        let data = Data("POST /hook/Stop HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        guard case .complete(let parsed) = HookServer.parseRequest(data) else {
            Issue.record("expected a complete parse"); return
        }
        #expect(parsed.body.isEmpty)
    }

    @Test func capturesTheSwarmBarTokenHeader() {
        let data = request(
            headers: "Content-Length: 2\r\nX-SwarmBar-Token: sample-header-value", body: "{}")
        guard case .complete(let parsed) = HookServer.parseRequest(data) else {
            Issue.record("expected a complete parse"); return
        }
        #expect(parsed.token == "sample-header-value")
    }

    @Test func missingTokenHeaderParsesAsNil() {
        let body = "{}"
        let data = request(headers: "Content-Length: \(body.utf8.count)", body: body)
        guard case .complete(let parsed) = HookServer.parseRequest(data) else {
            Issue.record("expected a complete parse"); return
        }
        #expect(parsed.token == nil)
    }
}

@MainActor
struct HookTokenTests {
    @Test func matchesOnlyTheExactToken() {
        #expect(HookToken.matches("abc123", "abc123"))
        #expect(!HookToken.matches("abc124", "abc123"))
        #expect(!HookToken.matches("abc123x", "abc123"))
        #expect(!HookToken.matches("", "abc123"))
        #expect(!HookToken.matches(nil, "abc123"))
    }

    @Test func mintedTokensAreLongAndUrlSafe() throws {
        let token = try #require(HookToken.loadOrCreate())
        #expect(token.count >= 40)
        #expect(!token.contains("/"))
        #expect(!token.contains("+"))
        #expect(!token.contains("="))
    }

    @Test func loadingTwiceReturnsTheSameToken() throws {
        let first = try #require(HookToken.loadOrCreate())
        let second = try #require(HookToken.loadOrCreate())
        #expect(first == second)
    }
}

/// Codex writes every spawned subagent its own rollout file beside its
/// parent's. On the machine where this was found, 147 of 172 rollouts were
/// subagents, so one Codex run filled the popover with rows carrying the
/// project's name that could never need the user.
@MainActor
struct CodexSubagentTests {
    private func meta(_ payload: String) -> String {
        #"{"type":"session_meta","payload":\#(payload)}"#
    }

    @Test func aSpawnedThreadIsASubagent() {
        let head = meta(#"{"cwd":"/tmp/p","session_id":"abc","thread_source":"subagent","agent_nickname":"Cicero"}"#)
        #expect(CodexSessionParser.isSubagent(head: head))
    }

    @Test func aRealSessionIsNot() {
        let head = meta(#"{"cwd":"/tmp/p","session_id":"abc","thread_source":"user"}"#)
        #expect(!CodexSessionParser.isSubagent(head: head))
    }

    /// Rollouts written before Codex had multi-agent support carry no
    /// marker. An absent field means "not known to be a subagent", so they
    /// are kept: reading absence as "subagent" would hide real sessions,
    /// which is a worse failure than showing one row too many.
    @Test func anOlderRolloutWithNoMarkerIsKept() {
        let head = meta(#"{"cwd":"/tmp/p","session_id":"abc"}"#)
        #expect(!CodexSessionParser.isSubagent(head: head))
    }

    @Test func junkDoesNotCrashOrMisclassify() {
        #expect(!CodexSessionParser.isSubagent(head: ""))
        #expect(!CodexSessionParser.isSubagent(head: "not json"))
        #expect(!CodexSessionParser.isSubagent(head: #"{"type":"event_msg"}"#))
    }

    /// cwd and session_id still parse from the same line the flag rides on.
    @Test func theRestOfTheMetadataStillParses() {
        let head = meta(#"{"cwd":"/tmp/p","session_id":"abc","thread_source":"subagent"}"#)
        let parsed = CodexSessionParser.meta(head: head)
        #expect(parsed.cwd == "/tmp/p")
        #expect(parsed.sessionId == "abc")
    }
}

/// Codex embeds base_instructions in its session_meta line, so the first
/// line of a rollout is now about 19 KB. The head window used to be a flat
/// 16 KB, which cut that line in half: it failed to parse, so every Codex
/// session lost its cwd and session id, showed as "codex session" with no
/// project path, and the subagent flag on the same line never registered.
@MainActor
struct CodexHeadWindowTests {
    private func rollout(firstLineBytes: Int) throws -> URL {
        let padding = String(repeating: "x", count: max(0, firstLineBytes - 200))
        let meta = #"{"type":"session_meta","payload":{"cwd":"/tmp/proj","session_id":"abc","thread_source":"subagent","base_instructions":"\#(padding)"}}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try (meta + "\n" + #"{"type":"event_msg"}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aSmallHeadStillParses() throws {
        let head = CodexMonitor.headText(of: try rollout(firstLineBytes: 500))
        #expect(CodexSessionParser.meta(head: head).cwd == "/tmp/proj")
    }

    /// The size that broke it. A real rollout measured 18,901 bytes.
    @Test func aNineteenKilobyteMetaLineParses() throws {
        let head = CodexMonitor.headText(of: try rollout(firstLineBytes: 19_000))
        let parsed = CodexSessionParser.meta(head: head)
        #expect(parsed.cwd == "/tmp/proj")
        #expect(parsed.sessionId == "abc")
        #expect(CodexSessionParser.isSubagent(head: head))
    }

    /// Headroom, so the next time Codex adds a field this does not silently
    /// regress to nameless rows.
    @Test func aMuchLargerMetaLineStillParses() throws {
        let head = CodexMonitor.headText(of: try rollout(firstLineBytes: 300_000))
        #expect(CodexSessionParser.meta(head: head).cwd == "/tmp/proj")
    }

    /// A file with no newline must not be read without bound.
    @Test func theWindowIsCapped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try String(repeating: "x", count: 2 * CodexMonitor.maxHeadBytes)
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(CodexMonitor.headText(of: url).count <= CodexMonitor.maxHeadBytes)
    }
}
