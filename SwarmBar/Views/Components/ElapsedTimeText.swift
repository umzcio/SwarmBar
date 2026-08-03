import SwiftUI

struct ElapsedTimeText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(.subheadline)
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
}
