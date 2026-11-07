import Foundation

/// What an approval row knows about the request its Approve button answers.
///
/// The rule this type exists for: Approve must never allow more than the
/// row lets the person see. Every source used to cut its request down
/// before the row ever saw it (an 80 character prefix, a basename, the
/// first line, the model's own one-line summary), and Approve then allowed
/// the whole thing. Now a source either hands over the WHOLE request,
/// verbatim, or says plainly that it could not read it, and only the
/// first kind can be approved from the popover. How much of an exact
/// request the row shows at once is the view's business, decided by
/// `ApprovalPreviewText`, which always marks a cut and always offers the
/// rest.
///
/// A string literal is an exact prompt, so `.waitingApproval(command: "ls")`
/// still reads the way it always has.
struct ApprovalPrompt: Equatable, Sendable, ExpressibleByStringLiteral {
    enum Fidelity: Equatable, Sendable {
        /// `text` is the complete request Approve answers.
        case exact
        /// SwarmBar could not read the request Approve would answer.
        /// `reason` says so in plain words, and the row offers the
        /// terminal instead of Approve. `text` is context at most (the
        /// agent's own description, say), and is never shown as if it
        /// were the request.
        case unreadable(reason: String)
    }

    let text: String
    let fidelity: Fidelity

    /// Past this the request is not shown in the popover at all, and the
    /// row sends the person to the terminal. A real command is nowhere
    /// near it; the cap is what keeps a hostile one from making the row
    /// unusable instead.
    static let maxCharacters = 32_000

    /// An exact request, unless it is too long to show, in which case it
    /// is not offered for approval here.
    init(_ text: String) {
        if text.count > Self.maxCharacters {
            self.text = ""
            self.fidelity = .unreadable(
                reason: "This request is too long to show here. Review it in the terminal.")
        } else {
            self.text = text
            self.fidelity = .exact
        }
    }

    init(stringLiteral value: String) { self.init(value) }

    private init(text: String, fidelity: Fidelity) {
        self.text = text
        self.fidelity = fidelity
    }

    static func unreadable(_ reason: String, context: String = "") -> ApprovalPrompt {
        ApprovalPrompt(text: context, fidelity: .unreadable(reason: reason))
    }

    var isExact: Bool { fidelity == .exact }

    /// The one rule every Approve path checks: only a request the row can
    /// show whole may be approved from it.
    var offersApprove: Bool { isExact }
}

/// The pure half of the approval preview: what text the row shows, whether
/// that is all of it, and what the banner says. Views are not unit tested
/// in this repo, so every decision about truncation lives here.
enum ApprovalPreviewText {
    /// Control characters and invisible formatting characters made visible.
    ///
    /// A terminal command can carry a carriage return, an escape sequence
    /// or a right-to-left override, and any of them can make the text on
    /// screen read differently from the bytes that run. Line feeds and
    /// tabs are kept as layout; everything else that does not draw is
    /// shown by name.
    static func visible(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09:
                out.append(scalar)
            case 0x00...0x1F:
                // The Control Pictures block mirrors C0 one for one.
                out.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case 0x7F:
                out.append(Unicode.Scalar(0x2421)!)
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    out.append(contentsOf: String(format: "<U+%04X>", scalar.value).unicodeScalars)
                default:
                    out.append(scalar)
                }
            }
        }
        return String(out)
    }

    struct Collapsed: Equatable {
        /// What the collapsed row shows, already made visible.
        let text: String
        /// Source lines not shown in full. Zero with `isCut` false means
        /// the collapsed text is the whole request.
        let hiddenLines: Int
        /// Whether anything at all was left out.
        let isCut: Bool
    }

    /// The first `maxLines` wrapped lines of a request, estimating a wrap
    /// every `columns` characters. The estimate only decides where the cut
    /// goes: the view lays the text out without a line limit, so a wrong
    /// estimate makes the block taller, never hides anything, and a cut is
    /// always marked and always offers the rest.
    static func collapsed(_ text: String, maxLines: Int = 4, columns: Int = 52) -> Collapsed {
        let shown = visible(text)
        let lines = shown.components(separatedBy: "\n")
        var kept: [String] = []
        var budget = max(1, maxLines)
        let width = max(1, columns)
        for (index, line) in lines.enumerated() {
            let rows = max(1, (line.count + width - 1) / width)
            if rows <= budget {
                kept.append(line)
                budget -= rows
                continue
            }
            // This line does not fit whole: show what the budget allows
            // of it, and everything from here on counts as hidden.
            if budget > 0 {
                kept.append(String(line.prefix(budget * width)))
            }
            return Collapsed(
                text: kept.joined(separator: "\n"),
                hiddenLines: lines.count - index,
                isCut: true)
        }
        return Collapsed(text: shown, hiddenLines: 0, isCut: false)
    }

    /// Whether a request reads in full on one compact line of `columns`
    /// characters. Compact rows offer Approve inline only then; anything
    /// longer opens the full preview first.
    static func fitsOneLine(_ text: String, columns: Int = 40) -> Bool {
        let shown = visible(text)
        return !shown.contains("\n") && shown.count <= columns
    }

    /// The label of the control that reveals the rest of a cut request.
    static func revealLabel(for collapsed: Collapsed) -> String {
        switch collapsed.hiddenLines {
        case 0, 1: "Show all"
        default: "Show all, \(collapsed.hiddenLines) more lines"
        }
    }

    /// The notification body. A banner cannot show a long request and has
    /// no Approve of its own, so a cut one says where the rest is rather
    /// than passing a prefix off as the whole.
    static func bannerBody(_ prompt: ApprovalPrompt) -> String {
        switch prompt.fidelity {
        case .unreadable(let reason):
            return reason
        case .exact:
            let short = collapsed(prompt.text, maxLines: 2, columns: 60)
            return short.isCut ? short.text + "… (more in SwarmBar)" : short.text
        }
    }

    /// The row's one line description of a request, for the "Running …"
    /// that follows an approval.
    static func firstWord(_ prompt: ApprovalPrompt) -> String {
        let text = visible(prompt.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? text
    }
}
