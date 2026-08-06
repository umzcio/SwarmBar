import SwiftUI

/// The prototype's action buttons: solid fills, 6pt radius, semibold 12pt,
/// slight press scale. borderedProminent washes tints out on macOS, so
/// these are drawn directly.
struct ActionPill: ButtonStyle {
    var background: AnyShapeStyle
    var foreground: AnyShapeStyle

    static let amber = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let amberText = Color(red: 0.14, green: 0.09, blue: 0.01)

    static var approve: ActionPill {
        ActionPill(background: AnyShapeStyle(amber), foreground: AnyShapeStyle(amberText))
    }
    static var deny: ActionPill {
        ActionPill(background: AnyShapeStyle(.primary.opacity(0.12)), foreground: AnyShapeStyle(.primary))
    }
    static var reply: ActionPill {
        ActionPill(background: AnyShapeStyle(.blue), foreground: AnyShapeStyle(.white))
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .swarmFont(.bodyEmphasis)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: 6))
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
