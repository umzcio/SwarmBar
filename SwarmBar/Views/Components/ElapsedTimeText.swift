import SwiftUI

/// Phase 2 replaces this with TimelineView(.periodic) and the prototype's
/// "8m 12s" formatting; the system timer style keeps phase 1 demoable.
struct ElapsedTimeText: View {
    let since: Date

    var body: some View {
        Text(since, style: .timer)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }
}
