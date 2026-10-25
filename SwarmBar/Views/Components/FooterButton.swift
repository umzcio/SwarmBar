import SwiftUI

/// The popover footer's text buttons (Settings, Quit). A borderless button
/// in a popover shows nothing under the pointer and nothing when pressed,
/// so a click never visibly landed. This one highlights like a row on
/// hover and firms up the instant it is pressed, as the action pills do.
struct FooterButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration)
    }

    private struct Appearance: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let lit = hovering || configuration.isPressed
            configuration.label
                .foregroundStyle(lit ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.primary.opacity(configuration.isPressed ? 0.13 : hovering ? 0.07 : 0),
                            in: .rect(cornerRadius: 6))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(.rect(cornerRadius: 6))
                .onHover { hovering = $0 }
                // Only the hover eases; a press shows at once.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}
