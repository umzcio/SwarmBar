import AppKit
import SwiftUI

/// Template-image constraint: encode state in shape and alpha, not color.
/// The glyph is the hexagongrid dot cluster, solid at rest. While agents
/// are active the dots light up in an order that traces an S through the
/// hexagon, then completes the full shape before looping.
struct MenuBarLabel: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: HexSwarmGlyph.image(step: step))
            if store.attentionCount > 0 {
                Text("\(store.attentionCount)")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
            }
        }
    }

    private var step: Int? {
        guard store.anyActive, !reduceMotion else { return nil }
        return store.iconPhase % 8
    }
}

/// Seven dots matching circle.hexagongrid, rasterized to cached template
/// NSImages (MenuBarExtra labels render SwiftUI drawing blank, and only
/// re-render on observable data changes).
enum HexSwarmGlyph {
    /// Light-up order: trace the S (top-right, top-left, center,
    /// bottom-right, bottom-left), then complete the hexagon with the two
    /// side dots.
    nonisolated static let sequence: [CGPoint] = {
        let cx = 8.0, cy = 7.5, ring = 4.9
        let dy = ring * sin(.pi / 3)
        return [
            CGPoint(x: cx + ring / 2, y: cy - dy),  // 1 top-right
            CGPoint(x: cx - ring / 2, y: cy - dy),  // 2 top-left
            CGPoint(x: cx, y: cy),                  // 3 center
            CGPoint(x: cx + ring / 2, y: cy + dy),  // 4 bottom-right
            CGPoint(x: cx - ring / 2, y: cy + dy),  // 5 bottom-left
            CGPoint(x: cx - ring, y: cy),           // 6 middle-left
            CGPoint(x: cx + ring, y: cy),           // 7 middle-right
        ]
    }()

    @MainActor private static var cache: [Int: NSImage] = [:]

    /// `step` 0...7 lights the first step+1 dots in sequence (7 holds the
    /// completed hexagon for a beat); nil renders the solid resting glyph.
    @MainActor
    static func image(step: Int?) -> NSImage {
        let litCount = min((step ?? 6) + 1, sequence.count)
        if let cached = cache[litCount] { return cached }

        let image = NSImage(size: NSSize(width: 16, height: 15), flipped: true) { _ in
            for (index, point) in sequence.enumerated() {
                let radius = 2.35
                NSColor.black.withAlphaComponent(index < litCount ? 1.0 : 0.3).setFill()
                NSBezierPath(ovalIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2
                )).fill()
            }
            return true
        }
        image.isTemplate = true
        cache[litCount] = image
        return image
    }
}
