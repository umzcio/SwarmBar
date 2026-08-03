import SwiftUI

enum AgentTool: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex, kimiCode, openCode
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex:      "Codex"
        case .kimiCode:   "Kimi Code"
        case .openCode:   "OpenCode"
        }
    }

    var glyph: String {
        switch self {
        case .claudeCode: "✳︎"
        case .codex:      "◎"
        case .kimiCode:   "K"
        case .openCode:   "O"
        }
    }

    /// Bundled monochrome logomark (SVG resource name); nil falls back to
    /// the text glyph.
    var logoResource: String? {
        switch self {
        case .claudeCode: "anthropic"
        case .codex:      "openai"
        case .kimiCode:   "kimi"
        case .openCode:   "opencode"
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:      Color(red: 0.10, green: 0.76, blue: 0.72)
        case .kimiCode:   Color(red: 0.30, green: 0.55, blue: 1.00)
        case .openCode:   Color(red: 0.42, green: 0.40, blue: 0.39)
        }
    }
}
