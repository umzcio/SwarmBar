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

    static func format(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static func agoFormat(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed))
        let minutes = totalSeconds / 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m ago" }
        if minutes > 0 { return "\(minutes)m ago" }
        return "just now"
    }
}
