import Foundation

/// The wizard's sentences that depend on counts and names, kept out of the
/// views so their grammar is tested.
enum WizardCopy {
    static func hosts(_ count: Int) -> String {
        count == 1 ? "1 host" : "\(count) hosts"
    }

    static func sessions(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    /// "The 2 Codex sessions here run as root." Shown above the watch-as
    /// choice, and only when someone else runs agents here.
    static func othersRunAs(_ context: RemoteWizardModel.WatchContext) -> String? {
        guard let count = context.otherSessions, count > 0 else { return nil }
        let users = context.otherUsers.joined(separator: ", ")
        if !context.otherSummary.contains(",") {
            return count == 1
                ? "The \(context.otherSummary) session here runs as \(users)."
                : "The \(context.otherSummary) sessions here run as \(users)."
        }
        return "\(count) sessions here run as \(users): \(context.otherSummary)."
    }

    /// Why watching every user does or doesn't work yet.
    static func loginLine(_ context: RemoteWizardModel.WatchContext) -> String {
        context.sudoOK
            ? "You log in as \(context.loginUser) with passwordless sudo, so SwarmBar can read them."
            : "You log in as \(context.loginUser) without passwordless sudo, so SwarmBar can't read them yet."
    }

    /// What a host watched as just the login user leaves out.
    static func hiddenLine(_ context: RemoteWizardModel.WatchContext) -> String? {
        guard let count = context.otherSessions, count > 0 else { return nil }
        let users = context.otherUsers.joined(separator: ", ")
        return count == 1
            ? "1 session runs as \(users) and isn't shown"
            : "\(count) sessions run as \(users) and aren't shown"
    }

    /// The done step's title for an undo.
    static func undoTitle(name: String, undone: Bool) -> String {
        undone ? "SwarmBar's changes were removed from \(name)." : "SwarmBar's changes are still on \(name)."
    }

    /// The lead for changes the paste prompt leaves out, naming only the
    /// ways that can make them here.
    static func omissionsLead(letSwarmBar: Bool, command: Bool) -> String {
        let ways = (letSwarmBar ? ["Let SwarmBar do it"] : []) + (command ? ["the command"] : [])
        guard !ways.isEmpty else {
            return "Left out of the prompt. Neither other way is available here, so these can't be made from this window:"
        }
        return "Left out of the prompt. Use \(ways.joined(separator: " or ")) for these:"
    }
}
