import AppKit
import SwiftUI

/// Template-image constraint: encode state in shape and alpha, not color.
/// The glyph is the app's S drawn as swarm dots: dimmed when idle, solid
/// when something needs attention, and while agents work a highlight
/// travels along the S so it continuously draws itself.
struct MenuBarLabel: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: SwarmSGlyph.image(
                crest: store.anyActive && !reduceMotion
                    ? store.iconPhase % SwarmSGlyph.dots.count
                    : nil,
                dimmed: !store.anyActive && store.attentionCount == 0
            ))
            if store.attentionCount > 0 {
                Text("\(store.attentionCount)")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
            }
        }
    }
}

/// Eight dots along the spine of an S, rasterized to a template NSImage.
/// MenuBarExtra labels do not reliably rasterize SwiftUI drawing (Canvas
/// renders blank), so this takes the sketch's NSImage route: black dots
/// with per-dot alpha, isTemplate = true, one cached image per frame.
enum SwarmSGlyph {
    nonisolated static let dots: [CGPoint] = [
        CGPoint(x: 9.8, y: 2.2),   // top-right terminal
        CGPoint(x: 6.0, y: 1.2),
        CGPoint(x: 2.8, y: 3.2),   // upper-left bulge
        CGPoint(x: 4.2, y: 6.4),
        CGPoint(x: 7.8, y: 8.8),   // crossing the center
        CGPoint(x: 9.2, y: 11.8),  // lower-right bulge
        CGPoint(x: 6.0, y: 13.9),
        CGPoint(x: 2.2, y: 12.9),  // bottom-left terminal
    ]

    @MainActor private static var cache: [Int: NSImage] = [:]

    /// `crest` is the brightest dot of the traveling wave; nil renders a
    /// static glyph, solid or dimmed.
    @MainActor
    static func image(crest: Int?, dimmed: Bool) -> NSImage {
        let key = crest ?? (dimmed ? -2 : -1)
        if let cached = cache[key] { return cached }

        let image = NSImage(size: NSSize(width: 12, height: 15), flipped: true) { _ in
            for (index, point) in dots.enumerated() {
                let radius: CGFloat = 1.3
                NSColor.black.withAlphaComponent(alpha(for: index, crest: crest, dimmed: dimmed)).setFill()
                NSBezierPath(ovalIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2
                )).fill()
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private nonisolated static func alpha(for index: Int, crest: Int?, dimmed: Bool) -> Double {
        guard let crest else { return dimmed ? 0.45 : 1.0 }
        let count = dots.count
        let distanceBehindCrest = (index - crest % count + count) % count
        switch distanceBehindCrest {
        case 0: return 1.0
        case 1: return 0.8
        case 2: return 0.6
        default: return 0.35
        }
    }
}
