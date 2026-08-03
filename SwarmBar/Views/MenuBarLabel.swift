import SwiftUI

/// Template-image constraint: encode state in shape, not color.
/// Phase 5 replaces this with the custom 4-dot swarm glyph; a plain
/// SF Symbol variant is fine until then.
struct MenuBarLabel: View {
    let anyActive: Bool
    let attentionCount: Int

    var body: some View {
        Image(systemName: attentionCount > 0
              ? "circle.hexagongrid.fill"
              : "circle.hexagongrid")
    }
}
