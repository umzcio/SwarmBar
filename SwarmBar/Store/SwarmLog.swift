import Foundation

/// The one way SwarmBar writes to the system log.
///
/// NSLog's first argument is a printf format, so text interpolated into it
/// has every `%` read as a conversion. Much of what SwarmBar logs comes
/// from outside the binary: a remote host's warnings, helper and ssh
/// output, hook ids, paths and error descriptions. A `%@` or `%s` in any of
/// it made NSLog read an argument that was never passed and dereference it,
/// which crashed the app, and a host that sent the same warning on every
/// first poll crashed it on every launch. Here the format is a constant and
/// the message only ever an argument, so its bytes are logged as they are.
enum SwarmLog {
    nonisolated static func log(_ message: String) {
        NSLog("%@", message as NSString)
    }
}
