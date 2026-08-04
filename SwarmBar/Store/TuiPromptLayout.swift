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

    /// The numbered options of the selector block nearest the bottom of the
    /// screen. A block is a run of ascending "N. Label" lines separated only
    /// by blank lines: agent prose often contains numbered lists, and pressing
    /// a digit chosen from one of those would answer a selector nobody read.
    nonisolated static func options(in screen: String) -> [Option] {
        var blocks: [[Option]] = []
        var current: [Option] = []

        func endBlock() {
            if current.count >= 2 { blocks.append(current) }
            current = []
        }

        for raw in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "▶►> \u{2502}\u{258F}"))
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }          // blank lines do not break a block
            guard let dot = line.firstIndex(of: "."),
                  let number = Int(line[line.startIndex..<dot]),
                  (1...9).contains(number)
            else { endBlock(); continue }         // prose ends the block
            let label = line[line.index(after: dot)...]
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { endBlock(); continue }
            if number == 1 { endBlock() }
            if number == current.count + 1 {
                current.append(Option(number: number, label: label))
            } else {
                endBlock()
            }
        }
        endBlock()
        return blocks.last ?? []
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
            if label.contains("reject") || label.contains("deny") { return true }
            // "No", "No, ...", "No thanks" are rejections; "Note:", "Not now",
            // and "No changes needed" are not selector rejections.
            let firstWord = label.split(whereSeparator: { $0 == " " || $0 == "," }).first
            return firstWord == "no"
        }
        let plain = rejections.first { !$0.label.lowercased().contains("feedback") }
        return (plain ?? rejections.first)?.number
    }

    /// `approveOnce`, but carrying the label so the caller can verify it is
    /// still on screen at that number before pressing.
    nonisolated static func approveOnceOption(in screen: String) -> Option? {
        approveOnce(in: screen).flatMap { number in
            options(in: screen).first { $0.number == number }
        }
    }

    /// `reject`, but carrying the label so the caller can verify it is
    /// still on screen at that number before pressing.
    nonisolated static func rejectOption(in screen: String) -> Option? {
        reject(in: screen).flatMap { number in
            options(in: screen).first { $0.number == number }
        }
    }
}
