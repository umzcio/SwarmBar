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
}
