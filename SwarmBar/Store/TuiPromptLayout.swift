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

    /// A selector as it is drawn, including which option the cursor sits
    /// on. Tools answered by arrow keys need that; tools answered by digit
    /// do not, and ignore it.
    struct Selector: Equatable {
        var options: [Option]
        /// The option the cursor marks, when the screen marks one.
        var cursor: Int?
        /// That line exactly as drawn, marker included ("> 1. Approve").
        /// Re-confirming the LABEL before pressing would prove nothing
        /// about the cursor, since the label is on screen wherever the
        /// cursor happens to be. The marked line is the thing that moves.
        var cursorLine: String?
    }

    /// Characters a TUI draws to the left of the highlighted row.
    nonisolated static let cursorMarkers = CharacterSet(charactersIn: "▶►>❯›➜")

    /// Which arrow key, pressed how many times, moves the cursor from
    /// where it is to the option wanted.
    ///
    /// Only ever the distance WITHIN the list, so this never presses past
    /// an end and wrapping cannot come into it. That is the whole point:
    /// Kimi's selector wraps, and eight blind DOWNs on a four-item prompt
    /// came back around to "Approve once" and approved a denied command.
    nonisolated static func navigation(from cursor: Int, to target: Int) -> (key: String, presses: Int)? {
        guard cursor > 0, target > 0 else { return nil }
        if target == cursor { return ("DOWN", 0) }
        return target > cursor
            ? ("DOWN", target - cursor)
            : ("UP", cursor - target)
    }

    /// The numbered options of the selector block nearest the bottom of the
    /// screen. A block is a run of ascending "N. Label" lines separated only
    /// by blank lines: agent prose often contains numbered lists, and pressing
    /// a digit chosen from one of those would answer a selector nobody read.
    nonisolated static func options(in screen: String) -> [Option] {
        selector(in: screen).options
    }

    nonisolated static func selector(in screen: String) -> Selector {
        var blocks: [Selector] = []
        var current = Selector(options: [], cursor: nil)

        func endBlock() {
            if current.options.count >= 2 { blocks.append(current) }
            current = Selector(options: [], cursor: nil, cursorLine: nil)
        }

        for raw in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = raw.trimmingCharacters(in: .whitespaces)
            let marked = stripped.unicodeScalars.first.map(cursorMarkers.contains) ?? false
            let line = stripped
                .trimmingCharacters(in: CharacterSet(charactersIn: "▶►>❯›➜ \u{2502}\u{258F}"))
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
            if number == current.options.count + 1 {
                current.options.append(Option(number: number, label: label))
                if marked {
                    current.cursor = number
                    current.cursorLine = stripped
                }
            } else {
                endBlock()
            }
        }
        endBlock()
        return blocks.last ?? Selector(options: [], cursor: nil)
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
