import Foundation

/// Escaping for values interpolated into AppleScript source.
///
/// Everything SwarmBar sends to a terminal is built by interpolating into a
/// script string, so any value carrying a quote or a backslash would end the
/// literal early and change what the script does. Until inline reply, every
/// interpolated value was a digit or a fixed token, which made this latent;
/// a user-written reply is the first caller that can contain anything.
enum AppleScriptLiteral {
    /// The contents of an AppleScript double-quoted string literal, escaped.
    ///
    /// Scalar by scalar, never by Character. osascript ends a literal at any
    /// U+0022, but a Character search only finds a quote standing alone: a
    /// quote fused into one grapheme with a combining mark after it
    /// (U+0301) or a prepending scalar before it (U+0600) is a Character
    /// that is not a quote, so it went out unescaped and ended the literal.
    /// A label read off a terminal is whatever the agent printed, so that
    /// was a way out of the string and into the script.
    nonisolated static func escape(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
    }

    /// An AppleScript expression for `raw`, with newlines rejoined using the
    /// `linefeed` constant. A literal newline cannot appear inside an
    /// AppleScript string literal, so multi-line text has to be concatenated.
    /// Empty input yields an empty literal rather than an empty expression.
    ///
    /// Split by scalar for the same reason `escape` works by scalar: "\r\n",
    /// or a newline with a combining mark after it, is one Character, and a
    /// Character split would leave that newline inside a literal.
    nonisolated static func expression(_ raw: String) -> String {
        let parts = raw.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        guard parts.count > 1 else { return "\"\(escape(raw))\"" }
        return parts
            .map { "\"\(escape($0))\"" }
            .joined(separator: " & linefeed & ")
    }
}
