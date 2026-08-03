import SwiftUI

struct StatusDot: View {
    let status: SessionStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private var animates: Bool { !reduceMotion && (status.pulses || status.blinks) }

    var body: some View {
        Circle()
            .fill(status.tint)
            .frame(width: 7, height: 7)
            .opacity(dimmed ? (status.blinks ? 0.25 : 0.55) : 1)
            .animation(
                animates
                    ? .easeInOut(duration: status.blinks ? 0.55 : 0.7).repeatForever(autoreverses: true)
                    : nil,
                value: dimmed
            )
            .onAppear { dimmed = animates }
            .onChange(of: animates) { _, nowAnimates in dimmed = nowAnimates }
    }
}
