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
    /// Backslash first: escaping it after the quote would double-escape the
    /// backslashes this function just added.
    nonisolated static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// An AppleScript expression for `raw`, with newlines rejoined using the
    /// `linefeed` constant. A literal newline cannot appear inside an
    /// AppleScript string literal, so multi-line text has to be concatenated.
    /// Empty input yields an empty literal rather than an empty expression.
    nonisolated static func expression(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "\n")
        guard parts.count > 1 else { return "\"\(escape(raw))\"" }
        return parts
            .map { "\"\(escape($0))\"" }
            .joined(separator: " & linefeed & ")
    }
}
