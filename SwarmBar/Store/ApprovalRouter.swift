import Foundation

/// Which channel answers a prompt, once a held decision has been ruled out.
///
/// This is the highest-stakes table in the app. Every entry was settled by
/// a live round against a real session, several of them are counterintuitive
/// enough that a reasonable person would guess wrong, and getting one wrong
/// does not fail loudly: it presses a key into somebody's terminal. Kimi's
/// selector wraps, so blind navigation once approved a command that had been
/// denied. Grok's hook runner ignores deny responses, so it cannot be
/// answered the way Claude is. A digit sent to Grok once turned a deny into
/// an approve.
///
/// It lived inside SessionStore as a run of `if session.tool ==` branches,
/// where it could only be exercised by driving a real terminal, so the one
/// thing worth testing was the one thing untestable. Pulling it out changes
/// no behavior and makes the table assertable.
enum ApprovalRoute: Equatable {
    /// A fixed key sequence for the session's tty. Positional, so the
    /// sequence itself encodes the layout.
    case keys([String])
    /// Read the selector off the screen and press the matching option's own
    /// number. For prompts that accept digits, where the number must be
    /// read rather than assumed.
    case numberedSelector
    /// Read the selector off the screen and walk the cursor to the matching
    /// option. For prompts that advertise arrows and say nothing about
    /// digits.
    case navigateSelector
    /// Nothing can answer remotely, so bring the user to the prompt.
    case focusTerminal
    /// A mock session with no project path: move the row along directly.
    /// Demo mode only, and never reachable for a real session.
    case mockTransition
}

enum ApprovalRouter {
    /// The settings and session facts the route depends on. Passed in
    /// rather than read from UserDefaults so the table can be tested at
    /// every combination without touching a real defaults store.
    struct Environment: Equatable {
        var grokKeystrokes: Bool
        var antigravityKeystrokes: Bool
        var hasProjectPath: Bool

        init(
            grokKeystrokes: Bool = true,
            antigravityKeystrokes: Bool = true,
            hasProjectPath: Bool = true
        ) {
            self.grokKeystrokes = grokKeystrokes
            self.antigravityKeystrokes = antigravityKeystrokes
            self.hasProjectPath = hasProjectPath
        }
    }

    /// `allow` picks approve or deny; several tools answer the two through
    /// completely different mechanisms, so it cannot be decided afterwards.
    static func route(
        tool: AgentTool, allow: Bool, in environment: Environment
    ) -> ApprovalRoute {
        switch tool {
        case .grokBuild:
            // Grok's hook runner ignores deny responses (all four dialects
            // verified live), so the prompt is answered at the TUI. Layouts
            // vary between three-option shell prompts and four-option edit
            // prompts, but reject is always last and plain approve-once is
            // second from last, so the sequence clamps to the bottom and
            // steps up once for approve. Never a digit: one deny sent as a
            // digit approved a write.
            guard environment.grokKeystrokes else { return .focusTerminal }
            return .keys(allow ? TuiAnswer.grokApprove : TuiAnswer.grokDeny)

        case .codex:
            // Labeled hotkeys rather than positions: y approves once, ESC
            // rejects and aborts the turn, which is the only deny Codex
            // offers. Both verified live against the decision records.
            return .keys(allow ? TuiAnswer.codexApprove : TuiAnswer.codexDeny)

        case .kimiCode, .bearCode:
            // The selector WRAPS, so a navigation count is unsafe: eight
            // DOWNs on a four-item prompt landed back on "Approve once".
            // Layouts differ too, so the digit is read off the screen and
            // re-confirmed, never assumed.
            return .numberedSelector

        case .antigravity:
            // Its prompt advertises arrows and enter and says nothing about
            // digits, so there is no evidence it takes one.
            guard environment.antigravityKeystrokes else { return .focusTerminal }
            return .navigateSelector

        case .claudeCode, .openCode:
            // Both answer only through a held decision, which the caller
            // has already tried by the time this is reached. Reaching here
            // means there was nothing to answer.
            return environment.hasProjectPath ? .focusTerminal : .mockTransition
        }
    }
}
