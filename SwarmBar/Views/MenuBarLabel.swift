import AppKit
import SwiftUI

/// Menu bar icon per the spec in CLAUDE.md and swarm-glyph-hexgrid.html
/// (Fill variant). The circle.hexagongrid seven-dot hexagon at all times:
/// solid when idle, the accumulate/hold/flush fill cycle while agents are
/// active, and center/ring alternation when sessions need attention.
struct MenuBarLabel: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: glyph)
            if store.attentionCount > 0 {
                Text("\(store.attentionCount)")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
            }
        }
    }

    private var glyph: NSImage {
        if reduceMotion { return SwarmGlyphRenderer.solid() }
        if store.attentionCount > 0 {
            return SwarmGlyphRenderer.attentionFrame(centerLit: store.iconPhase % 2 == 0)
        }
        if store.anyActive, !store.isPaused {
            return SwarmGlyphRenderer.fillFrame(store.iconPhase % 9)
        }
        return SwarmGlyphRenderer.solid()
    }
}

/// Draws the seven fixed circles into cached template NSImages, one frame
/// per tick. (MenuBarExtra labels render SwiftUI drawing blank and only
/// re-render on observable data changes, hence pre-rendered frames driven
/// by the store's ticker.)
enum SwarmGlyphRenderer {
    /// Fill order: 1 top-right, 2 top-left, 3 center, 4 bottom-right,
    /// 5 bottom-left, 6 mid-left, 7 mid-right. Geometry matches the
    /// prototype's 16px glyph.
    nonisolated static let sequence: [CGPoint] = [
        CGPoint(x: 10.6, y: 3.5),   // 1 top-right
        CGPoint(x: 5.4, y: 3.5),    // 2 top-left
        CGPoint(x: 8.0, y: 8.0),    // 3 center
        CGPoint(x: 10.6, y: 12.5),  // 4 bottom-right
        CGPoint(x: 5.4, y: 12.5),   // 5 bottom-left
        CGPoint(x: 2.8, y: 8.0),    // 6 mid-left
        CGPoint(x: 13.2, y: 8.0),   // 7 mid-right
    ]

    private static let centerIndex = 2
    private static let unlitAlpha = 0.25

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func solid() -> NSImage {
        frame(key: "solid") { _ in 1.0 }
    }

    /// One step of the fill cycle: 0 flushes to empty, 1...7 accumulate
    /// that many dots in sequence, 8 holds the full hexagon.
    @MainActor
    static func fillFrame(_ step: Int) -> NSImage {
        let litCount = step == 8 ? 7 : step
        return frame(key: "fill-\(litCount)") { index in
            index < litCount ? 1.0 : unlitAlpha
        }
    }

    /// Needs-attention: center dot and outer ring lit in alternation.
    @MainActor
    static func attentionFrame(centerLit: Bool) -> NSImage {
        frame(key: "attn-\(centerLit)") { index in
            (index == centerIndex) == centerLit ? 1.0 : unlitAlpha
        }
    }

    @MainActor
    private static func frame(key: String, alpha: @escaping @Sendable (Int) -> Double) -> NSImage {
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            for (index, point) in sequence.enumerated() {
                let radius = 2.0
                NSColor.black.withAlphaComponent(alpha(index)).setFill()
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
}
