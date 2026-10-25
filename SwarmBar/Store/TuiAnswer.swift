import Foundation

/// The exact keystroke sequences that answer each tool's TUI permission
/// prompt. Extracted from SessionStore so they can be asserted: a wrong
/// count here once approved a command the user had denied, and the only
/// other way to check them is a live round with a real agent.
///
/// These values are verified against live prompts. Do not "clean them up"
/// without a fresh live verification per tool.
enum TuiAnswer {
    /// Codex's approval modal has labeled hotkeys: y approves once, esc
    /// rejects and aborts the turn (the only deny Codex offers).
    static let codexApprove: [String] = ["y"]
    static let codexDeny: [String] = ["ESC"]
}
