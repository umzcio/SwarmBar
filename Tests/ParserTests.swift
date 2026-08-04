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
