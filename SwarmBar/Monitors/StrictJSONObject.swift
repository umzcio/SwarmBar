import Foundation

/// A JSON object read out of text that something else wrote, for an
/// approval row to show. Stricter than JSONSerialization alone, because the
/// text is read by two parsers that must agree on what it says: the agent
/// that acts on it and SwarmBar that shows it.
enum StrictJSONObject {
    /// A JSON object starting exactly at `start` (after whitespace), with
    /// where it ends. Refused when a top-level key is repeated or written
    /// with an escape: JavaScript and a JSON parser need not agree on
    /// which of two `cmd` keys wins, and `"c\u006dd"` is `cmd` to both.
    nonisolated static func parse(
        in text: String, from start: String.Index
    ) -> (object: [String: Any], end: String.Index)? {
        var index = start
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex, text[index] == "{" else { return nil }
        let open = index
        var depth = 0
        var inString = false
        var escaped = false
        var stringStart = index
        var stringHasEscape = false
        var keys = Set<String>()
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                    stringHasEscape = true
                } else if character == "\"" {
                    inString = false
                    if depth == 1 {
                        // A top-level string followed by a colon is a key.
                        var next = text.index(after: index)
                        while next < text.endIndex, text[next].isWhitespace {
                            next = text.index(after: next)
                        }
                        if next < text.endIndex, text[next] == ":" {
                            let key = String(text[text.index(after: stringStart)..<index])
                            guard !stringHasEscape, keys.insert(key).inserted else { return nil }
                        }
                    }
                }
            } else if character == "\"" {
                inString = true
                stringStart = index
                stringHasEscape = false
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: index)
                    guard let data = String(text[open..<end]).data(using: .utf8),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    else { return nil }
                    return (object, end)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
