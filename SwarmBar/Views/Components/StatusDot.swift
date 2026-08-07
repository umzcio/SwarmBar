import SwiftUI

/// Active statuses pulse an expanding halo ring (the dot itself stays solid);
/// attention statuses blink the dot hard. Both gate on reduce motion. The
/// parent gives this view a fresh identity per status kind so the
/// repeatForever loops restart on category changes.
struct StatusDot: View {
    @Environment(\.swarmScale) private var scale
    let status: SessionStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(status.tint)
            .frame(width: 7 * scale, height: 7 * scale)
            .opacity(status.blinks && phase ? 0.25 : 1)
            .background {
                if status.pulses && !reduceMotion {
                    Circle()
                        .stroke(status.tint.opacity(phase ? 0 : 0.5), lineWidth: 3)
                        .scaleEffect(phase ? 2.4 : 1)
                }
            }
            .onAppear { start() }
            // Decorative: the colour repeats what the adjacent status text
            // already says, in both densities. Announcing it would just
            // add an anonymous element before every row.
            .accessibilityHidden(true)
    }

    private func start() {
        guard !reduceMotion else { return }
        if status.blinks {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                phase = true
            }
        } else if status.pulses {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = true
            }
        }
    }
}
