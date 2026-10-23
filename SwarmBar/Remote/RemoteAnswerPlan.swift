import Foundation

/// What to press in a remote session's tmux pane, and what must still be
/// on its screen when the helper presses it. The helper re-reads the pane
/// immediately before sending and sends nothing if any `expect` string is
/// missing, which is the remote form of the local path's one-script read
/// and press.
struct RemoteKeyCommand: Equatable, Sendable {
    var keys: [String]
    var expect: [String]
}

/// Turns the route `ApprovalRouter` chose into a key command, from a screen
/// the helper captured. Pure, so the one table that decides which keys land
/// in somebody's live session on a server is assertable without one.
///
/// Every rule here is the local path's, unchanged: the same router, the same
/// selector reader, the same fixed sequences and the same strings
/// re-confirmed before pressing. A remote session gets no answer the local
/// one would not, so nothing settled by a live round is re-derived.
enum RemoteAnswerPlan {
    /// Nil whenever nothing can be pressed safely, which leaves the row as
    /// it is rather than guessing at a prompt nobody read.
    static func command(
        route: ApprovalRoute, screen: String?,
        choose: (String) -> TuiPromptLayout.Option?
    ) -> RemoteKeyCommand? {
        switch route {
        case .keys(let keys):
            // Fixed sequences are positional or hotkeys, verified live as
            // they are and sent unconfirmed exactly as the local path sends
            // them to a tty.
            return RemoteKeyCommand(keys: keys, expect: [])

        case .numberedSelector:
            // The digit is read off the screen, never assumed, and its label
            // is what the helper re-confirms, as TerminalFocuser.answerNumbered
            // does locally.
            guard let screen, let option = choose(screen) else { return nil }
            return RemoteKeyCommand(keys: ["\(option.number)"], expect: [option.label])

        case .navigateSelector:
            // Walked by label from the marked line, only ever the distance
            // within the list, so a wrapping selector cannot come into it.
            // The marked line is confirmed as well as the label, since the
            // label is on screen wherever the cursor happens to be, as in
            // TerminalFocuser.answerByNavigation.
            guard let screen, let option = choose(screen) else { return nil }
            let selector = TuiPromptLayout.selector(in: screen)
            guard let cursor = selector.cursor,
                  let cursorLine = selector.cursorLine,
                  let move = TuiPromptLayout.navigation(from: cursor, to: option.number)
            else { return nil }
            return RemoteKeyCommand(
                keys: Array(repeating: move.key, count: move.presses) + ["\n"],
                expect: [option.label, cursorLine])

        case .focusTerminal, .mockTransition:
            return nil
        }
    }

    /// Whether the route chooses its keys from the screen, and so needs a
    /// capture first. A fixed sequence is pressed without one, as locally.
    static func needsScreen(_ route: ApprovalRoute) -> Bool {
        switch route {
        case .numberedSelector, .navigateSelector: true
        case .keys, .focusTerminal, .mockTransition: false
        }
    }

    /// `needsScreen`, plus Grok: see `command(tool:route:screen:choose:)`.
    static func needsScreen(tool: AgentTool, route: ApprovalRoute) -> Bool {
        if tool == .grokBuild, case .keys = route { return true }
        return needsScreen(route)
    }

    /// `command(route:screen:choose:)` with one remote-only gate. Grok's
    /// fixed sequence (eight DOWNs, then UP or Enter, then Enter) is only
    /// pressed where a selector is drawn. Locally the session's own tty is
    /// known to be at the prompt; remotely the pane is matched from a
    /// snapshot, and the same keys at a bare shell recall a history line
    /// and run it. The selector's labels go along as `expect`, so the
    /// helper re-confirms it is still on screen at press time. Codex is
    /// not gated: "y" or ESC at a shell does nothing worth guarding.
    static func command(
        tool: AgentTool, route: ApprovalRoute, screen: String?,
        choose: (String) -> TuiPromptLayout.Option?
    ) -> RemoteKeyCommand? {
        guard tool == .grokBuild, case .keys(let keys) = route else {
            return command(route: route, screen: screen, choose: choose)
        }
        guard let screen else { return nil }
        let options = TuiPromptLayout.selector(in: screen).options
        guard options.count >= 2 else { return nil }
        return RemoteKeyCommand(keys: keys, expect: options.map(\.label))
    }

    /// The visible screen from a `capture` reply, or nil for an error reply
    /// or anything unreadable. Success replies carry no `ok` field, so an
    /// explicit `ok: false` is the error and the text is the success.
    static func screen(fromCapture data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["ok"] as? Bool != false
        else { return nil }
        return object["text"] as? String
    }

    /// A reply as the helper will paste it: C0 controls other than newline
    /// and tab, and DEL, removed by the same rule as the helper's
    /// PASTE_STRIP. Stripped here too so the on-screen probe is taken from
    /// the text that actually lands, not from text the helper will alter.
    /// By scalar, because "\r\n" is one Character and would otherwise be
    /// kept or dropped whole.
    static func pasteText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F)
        })
        return String(scalars)
    }

    enum PasteOutcome: Equatable {
        case pasted
        /// Refused before anything was typed: the target changed, or the
        /// request itself was rejected.
        case refused(String)
        /// A step failed partway, or the reply could not be read, so some
        /// of the text may be in the composer.
        case uncertain(String)
    }

    /// Unlike keys, a paste's failures differ in what they leave behind,
    /// and a reply that says "nothing was sent" over half a paste invites
    /// a second Send that pastes it twice.
    static func pasteOutcome(from data: Data) -> PasteOutcome {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .uncertain("unreadable reply")
        }
        if object["ok"] as? Bool == false {
            return .refused(object["error"] as? String ?? "error")
        }
        if object["sent"] as? Bool == true { return .pasted }
        let reason = object["reason"] as? String ?? "not sent"
        return reason == "changed" ? .refused(reason) : .uncertain(reason)
    }

    enum KeysOutcome: Equatable {
        case sent
        /// The helper's reason, or the error it returned instead.
        case notSent(String)
    }

    /// Only an explicit `sent: true` counts. Anything else, including a
    /// reply that does not parse, is treated as nothing pressed, because
    /// moving the row on for keys that never landed would hide a prompt
    /// that is still waiting.
    static func keysOutcome(from data: Data) -> KeysOutcome {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .notSent("unreadable reply")
        }
        if object["ok"] as? Bool == false {
            return .notSent(object["error"] as? String ?? "error")
        }
        if object["sent"] as? Bool == true { return .sent }
        let reason = object["reason"] as? String ?? "not sent"
        // A send that failed partway left some keys in the pane, and how
        // many is the one thing the log reader needs to know.
        if let count = object["sent_count"] as? Int {
            return .notSent("\(reason) (sent_count \(count))")
        }
        return .notSent(reason)
    }
}
