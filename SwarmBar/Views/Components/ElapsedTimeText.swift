import SwiftUI

struct ElapsedTimeText: View {
    let since: Date
    /// Finished rows read "how long ago", not a running duration; the
    /// coarser format stops the seconds from visibly ticking.
    var ago: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: ago ? 30 : 1)) { context in
            Text(ago
                 ? Self.agoFormat(context.date.timeIntervalSince(since))
                 : Self.format(context.date.timeIntervalSince(since)))
                .swarmFont(.meta)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// Past this the timer stops counting. A session's dates come from
    /// tool state files, local or a remote host's, so the interval can be
    /// anything at all, and Int(_:) traps on a Double outside Int's range.
    /// A century is far beyond any real session and well inside an Int.
    static let longestShown: TimeInterval = 100 * 365 * 24 * 60 * 60

    /// Whole seconds, clamped before the Int conversion rather than after:
    /// non-finite and negative intervals read as zero.
    static func wholeSeconds(_ elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return Int(min(elapsed, longestShown))
    }

    static func format(_ elapsed: TimeInterval) -> String {
        let totalSeconds = wholeSeconds(elapsed)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static func agoFormat(_ elapsed: TimeInterval) -> String {
        let totalSeconds = wholeSeconds(elapsed)
        let minutes = totalSeconds / 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m ago" }
        if minutes > 0 { return "\(minutes)m ago" }
        return "just now"
    }
}
