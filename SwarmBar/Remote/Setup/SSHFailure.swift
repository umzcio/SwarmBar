import Foundation

/// Why the wizard could not look at a host, in words that say what to fix.
enum HostProblem: Equatable, Sendable {
    case needsPassword, keyRejected, hostKeyChanged, timedOut, unresolvable, noPython
    /// The version the host reported, when it got far enough to say.
    case pythonTooOld(String?)
    case other(String)

    /// Plain text on purpose: a SwiftUI Text shows backticks literally, so
    /// the command name carries none.
    var message: String {
        switch self {
        case .needsPassword: "Asks for a password. Add your key with ssh-copy-id."
        case .keyRejected: "Your key isn't accepted"
        case .hostKeyChanged: "Host key changed. Check it before connecting."
        case .timedOut: "Timed out after 10 s"
        case .unresolvable: "Name doesn't resolve"
        case .noPython: "python3 isn't installed"
        case .pythonTooOld(nil): "python3 is too old (needs 3.9)"
        case .pythonTooOld(let version?): "python3 is too old (needs 3.9), found \(version)"
        case .other(let text): text
        }
    }
}

/// Sorts a failed probe ssh into a HostProblem from what ssh, the remote
/// shell or python printed. BatchMode is on, so ssh never prompts: every
/// one of these arrives as text on stderr.
enum SSHFailure {
    static func classify(stderr: String, exitStatus: Int32) -> HostProblem {
        // A changed key is checked first: ssh prints its warning and then
        // refuses before any authentication happens, and the warning block
        // mentions keys and passwords in passing.
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return .hostKeyChanged
        }
        // A host that is merely unknown also ends in "Host key verification
        // failed", after saying no key is known. Calling that "changed"
        // would alarm someone over a host they have never connected to.
        if stderr.contains("Host key verification failed") {
            if stderr.contains("host key is known for") {
                return .other("Host key isn't known yet. Connect once in a terminal to check it.")
            }
            return .hostKeyChanged
        }
        if stderr.contains("Permission denied") {
            // keyboard-interactive is how most servers ask for a password.
            let lowered = stderr.lowercased()
            if lowered.contains("password") || lowered.contains("passphrase")
                || lowered.contains("keyboard-interactive") {
                return .needsPassword
            }
            if stderr.contains("Permission denied (publickey)") { return .keyRejected }
        }
        if stderr.contains("Could not resolve hostname") { return .unresolvable }
        if stderr.lowercased().contains("timed out") { return .timedOut }
        // bash says "command not found", dash says "not found".
        if stderr.contains("python3: command not found") || stderr.contains("python3: not found")
            || exitStatus == 127 {
            return .noPython
        }
        // A python old enough not to parse the helper fails before it can
        // report its own version.
        if stderr.contains("SyntaxError") { return .pythonTooOld(nil) }
        let line = SSHChannel.firstLine(of: Data(stderr.utf8))
        return .other(line.isEmpty ? "ssh exited \(exitStatus)" : line)
    }
}
