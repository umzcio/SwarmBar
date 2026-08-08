import SwiftUI

enum AgentTool: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex, kimiCode, bearCode, openCode, grokBuild, antigravity
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex:      "Codex"
        case .kimiCode:   "Kimi Code"
        case .bearCode:   "BearCode"
        case .openCode:   "OpenCode"
        case .grokBuild:  "Grok Build"
        // Google retired the `gemini` CLI in favour of `agy`.
        case .antigravity: "Antigravity"
        }
    }

    var glyph: String {
        switch self {
        case .claudeCode: "✳︎"
        case .codex:      "◎"
        case .kimiCode:   "K"
        case .bearCode:   "B"
        case .openCode:   "O"
        case .grokBuild:  "X"
        case .antigravity: "▲"
        }
    }

    /// Bundled monochrome logomark (SVG resource name); nil falls back to
    /// the text glyph.
    var logoResource: String? {
        switch self {
        case .claudeCode: "anthropic"
        case .codex:      "openai"
        case .kimiCode:   "kimi"
        case .bearCode:   "bearcode"
        case .openCode:   "opencode"
        case .grokBuild:  "xai"
        // No bundled logomark yet, so the glyph is used.
        case .antigravity: nil
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:      Color(red: 0.10, green: 0.76, blue: 0.72)
        case .kimiCode:   Color(red: 0.30, green: 0.55, blue: 1.00)
        case .bearCode:   Color(red: 0.87, green: 0.54, blue: 0.20)
        case .openCode:   Color(red: 0.42, green: 0.40, blue: 0.39)
        case .grokBuild:  Color(red: 0.29, green: 0.31, blue: 0.36)
        case .antigravity: Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }
}
