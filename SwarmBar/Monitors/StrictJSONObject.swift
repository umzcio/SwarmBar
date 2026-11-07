import Foundation

/// A JSON object read out of text that something else wrote, for an
/// approval row to show. Stricter than JSONSerialization alone, because the
/// text is read by two parsers that must agree on what it says: the agent
/// that acts on it and SwarmBar that shows it.
enum StrictJSONObject {
    /// A JSON object starting exactly at `start` (after whitespace), with
    /// where it ends. Refused when a top-level key is repeated or written
    /// with an escape: JavaScript and a JSON parser need not agree on
    /// which of two `cmd` keys wins, and `"cmd"` is `cmd` to both.
    /// `__proto__` is refused too, since in a JavaScript literal it sets
    /// the prototype rather than naming a field.
    ///
    /// Scanned scalar by scalar, never by Character. Both parsers read a
    /// quote wherever a U+0022 scalar is, but a quote fused into one
    /// grapheme with a combining mark after it (U+0301, U+200D) or a
    /// prepending scalar before it (U+0600) is a Character that is not a
    /// quote. A Character scan then loses track of which text is inside a
    /// string, and keys in between are never checked. Every character
    /// that matters here is ASCII, so a scalar is exactly what both
    /// parsers see. `end` is a scalar boundary and need not be a Character
    /// boundary: read what follows through `unicodeScalars`.
    ///
    /// `checkingKeys: false` keeps the scalar scan and drops the key rules,
    /// for text that is only ever context (a summary), never the request.
    nonisolated static func parse(
        in text: String, from start: String.Index, checkingKeys: Bool = true
    ) -> (object: [String: Any], end: String.Index)? {
        let scalars = text.unicodeScalars
        var index = start
        while index < scalars.endIndex, scalars[index].properties.isWhitespace {
            index = scalars.index(after: index)
        }
        guard index < scalars.endIndex, scalars[index] == "{" else { return nil }
        let open = index
        var depth = 0
        var inString = false
        var escaped = false
        var stringStart = index
        var stringHasEscape = false
        // Compared as Strings, which match by canonical equivalence: a
        // superset of scalar equality, so two keys that differ only in
        // normalization are refused too rather than left to the bridge
        // into a Swift dictionary to pick between.
        var keys = Set<String>()
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                    stringHasEscape = true
                } else if scalar == "\"" {
                    inString = false
                    if depth == 1, checkingKeys {
                        // A top-level string followed by a colon is a key.
                        var next = scalars.index(after: index)
                        while next < scalars.endIndex, scalars[next].properties.isWhitespace {
                            next = scalars.index(after: next)
                        }
                        if next < scalars.endIndex, scalars[next] == ":" {
                            let key = String(scalars[scalars.index(after: stringStart)..<index])
                            guard !stringHasEscape,
                                  key != "__proto__",
                                  keys.insert(key).inserted
                            else { return nil }
                        }
                    }
                }
            } else if scalar == "\"" {
                inString = true
                stringStart = index
                stringHasEscape = false
            } else if scalar == "{" || scalar == "[" {
                depth += 1
            } else if scalar == "}" || scalar == "]" {
                depth -= 1
                if depth == 0 {
                    let end = scalars.index(after: index)
                    let data = Data(String(scalars[open..<end]).utf8)
                    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    else { return nil }
                    return (object, end)
                }
            }
            index = scalars.index(after: index)
        }
        return nil
    }
}
