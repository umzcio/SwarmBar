import Foundation

struct ParsedStatus: Equatable, Sendable {
    var status: SessionStatus
    var cwd: String?
}

/// Maps the tail of a Claude Code session JSONL to a SessionStatus.
/// Lines are type-tagged JSON: "assistant" lines carry tool_use / text in
/// message.content, "user" lines carry prompts or tool_result items, and
/// everything else (system, mode, last-prompt, file-history-*, ...) is
/// metadata with no status meaning.
enum ClaudeSessionParser {
    static let staleAfter: TimeInterval = 30 * 60
    static let toolStaleAfter: TimeInterval = 10 * 60

    static func parse(tail: String, now: Date = .now) -> ParsedStatus? {
        var cwd: String?
        for raw in tail.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = line["type"] as? String
            else { continue }
            if cwd == nil { cwd = line["cwd"] as? String }
            let age = (line["timestamp"] as? String)
                .flatMap { date($0) }
                .map { now.timeIntervalSince($0) }

            switch type {
            case "assistant":
                if let tool = contentItems(of: line)?.last(where: { ($0["type"] as? String) == "tool_use" }) {
                    if let age, age > toolStaleAfter { return ParsedStatus(status: .idle, cwd: cwd) }
                    return ParsedStatus(status: .runningTool(activity: toolActivity(tool)), cwd: cwd)
                }
                let text = assistantText(of: line)
                guard !text.isEmpty else { continue }
                if let age, age > staleAfter { return ParsedStatus(status: .idle, cwd: cwd) }
                return ParsedStatus(status: .waitingInput(prompt: prompt(from: text)), cwd: cwd)
            case "user":
                if let age, age > staleAfter { return ParsedStatus(status: .idle, cwd: cwd) }
                let hasToolResult = contentItems(of: line)?
                    .contains { ($0["type"] as? String) == "tool_result" } ?? false
                return ParsedStatus(
                    status: .working(activity: hasToolResult ? "Working through tool results…" : "Thinking…"),
                    cwd: cwd
                )
            default:
                continue
            }
        }
        return nil
    }

    /// "-Users-zach-GitHub-SwarmBar" is the cwd with "/" replaced by "-".
    /// Ambiguous when path components contain hyphens; the cwd field on
    /// JSONL lines is preferred and this is only a fallback.
    static func decodeProjectDir(_ name: String) -> String? {
        guard name.hasPrefix("-") else { return nil }
        return name.replacingOccurrences(of: "-", with: "/")
    }

    private static func contentItems(of line: [String: Any]) -> [[String: Any]]? {
        guard let message = line["message"] as? [String: Any] else { return nil }
        return message["content"] as? [[String: Any]]
    }

    private static func assistantText(of line: [String: Any]) -> String {
        if let items = contentItems(of: line) {
            return items
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
        }
        return ((line["message"] as? [String: Any])?["content"] as? String) ?? ""
    }

    private static func toolActivity(_ tool: [String: Any]) -> String {
        let name = tool["name"] as? String ?? "tool"
        if name == "Bash",
           let command = (tool["input"] as? [String: Any])?["command"] as? String {
            return "Running \(truncate(command.replacingOccurrences(of: "\n", with: " "), to: 48))"
        }
        return "Running \(name)"
    }

    private static func prompt(from text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return truncate(firstLine.trimmingCharacters(in: .whitespaces), to: 90)
    }

    private static func truncate(_ string: String, to limit: Int) -> String {
        string.count <= limit ? string : String(string.prefix(limit)) + "…"
    }

    // ISO8601DateFormatter is documented thread-safe; the unsafe marker is
    // only quieting strict concurrency's inability to see that.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    static func date(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
