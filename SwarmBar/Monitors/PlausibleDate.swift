import Foundation

/// The range a timestamp read out of a tool's state file, or a remote
/// host's manifest, has to fall in before it is used as a date.
///
/// Those numbers are whatever the file says, and on a remote host the file
/// may be another user's. Taken as is, 1e300 seconds dates a session
/// further ahead than a Date can count to in an Int, and a far-future date
/// also passes every discovery window, since its age comes out negative, so
/// the row would never age out either. Nothing an agent writes predates
/// 2000, and a host's clock may run somewhat ahead of this Mac's, so a day
/// of slack is allowed on that side and anything beyond it is treated as no
/// date at all.
enum PlausibleDate {
    static let earliest = Date(timeIntervalSince1970: 946_684_800)  // 2000-01-01
    static let futureSlack: TimeInterval = 24 * 60 * 60

    /// `date` when it falls between `earliest` and a day past `now`, else nil.
    nonisolated static func check(_ date: Date?, now: Date = .now) -> Date? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
              date >= earliest,
              date <= now.addingTimeInterval(futureSlack)
        else { return nil }
        return date
    }

    /// Seconds since 1970 as a date, under the same rule.
    nonisolated static func epoch(_ seconds: Double, now: Date = .now) -> Date? {
        guard seconds.isFinite else { return nil }
        return check(Date(timeIntervalSince1970: seconds), now: now)
    }
}
