import Foundation

/// The exact keystroke sequences that answer each tool's TUI permission
/// prompt. Extracted from SessionStore so they can be asserted: a wrong
/// count here once approved a command the user had denied, and the only
/// other way to check them is a live round with a real agent.
///
/// These values are verified against live prompts. Do not "clean them up"
/// without a fresh live verification per tool.
enum TuiAnswer {
    /// Grok's selector clamps at the bottom, so navigation is: clamp down,
    /// step up once to plain approve-once, submit.
    static let grokApprove: [String] = Array(repeating: "DOWN", count: 8) + ["UP", "\n"]

    /// Reject is the last option in every observed Grok layout: clamp to the
    /// bottom and submit. The second newline submits the reject feedback
    /// field empty.
    static let grokDeny: [String] = Array(repeating: "DOWN", count: 8) + ["\n", "\n"]

    /// Codex's approval modal has labeled hotkeys: y approves once, esc
    /// rejects and aborts the turn (the only deny Codex offers).
    static let codexApprove: [String] = ["y"]
    static let codexDeny: [String] = ["ESC"]
}
