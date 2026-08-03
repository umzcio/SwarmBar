import Foundation

/// Reads a TUI permission selector off the terminal's visible text so an
/// answer targets a labeled option instead of a guessed position.
///
/// Blind navigation is not safe here: Kimi's selector wraps around, so a
/// clamp of eight DOWNs on a four-item list lands back on "Approve once"
/// (it approved a command that was denied from SwarmBar). Blind digits
/// are not safe either, since layouts differ between shell and edit
/// prompts. Reading the options makes the digit verified rather than
/// assumed: find the numbered lines, match the intent by label, send that
/// number.
enum TuiPromptLayout {
    struct Option: Equatable {
        var number: Int
        var label: String
    }

    /// The numbered options of the last selector block on screen. Lines
    /// look like "  1. Approve once" (Kimi) with the marker glyph and
    /// indentation varying by tool.
    nonisolated static func options(in screen: String) -> [Option] {
        var found: [Option] = []
        for raw in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "▶►> \u{2502}\u{258F}"))
                .trimmingCharacters(in: .whitespaces)
            guard let dot = line.firstIndex(of: "."),
                  let number = Int(line[line.startIndex..<dot]),
                  (1...9).contains(number)
            else { continue }
            let label = line[line.index(after: dot)...]
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            // A new "1." starts a fresh block; keep only the latest.
            if number == 1 { found.removeAll() }
            if number == found.count + 1 { found.append(Option(number: number, label: label)) }
        }
        return found
    }

    /// The option number that approves this one call, preferring the
    /// once-only choice over any always/session-wide variant.
    nonisolated static func approveOnce(in screen: String) -> Int? {
        let options = options(in: screen)
        let approvals = options.filter { option in
            let label = option.label.lowercased()
            return (label.contains("approve") || label.contains("yes") || label.contains("allow"))
                && !label.contains("don't ask")
                && !label.contains("always")
                && !label.contains("session")
        }
        return approvals.first?.number
    }

    /// The option number that rejects the call, preferring a plain reject
    /// over one that opens a feedback field.
    nonisolated static func reject(in screen: String) -> Int? {
        let options = options(in: screen)
        let rejections = options.filter { option in
            let label = option.label.lowercased()
            return label.contains("reject") || label.contains("deny") || label.hasPrefix("no")
        }
        let plain = rejections.first { !$0.label.lowercased().contains("feedback") }
        return (plain ?? rejections.first)?.number
    }
}
