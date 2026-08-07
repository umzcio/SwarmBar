import AppKit
import SwiftUI

struct ToolChip: View {
    let tool: AgentTool
    let size: CGFloat

    var body: some View {
        Group {
            if let logo = ProviderLogo.image(for: tool) {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.58, height: size * 0.58)
            } else {
                Text(tool.glyph)
                    .font(.system(size: size * 0.5, weight: .heavy))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(tool.tint.gradient, in: .rect(cornerRadius: size * 0.27))
        .help(tool.label)
        // A compact row names the tool nowhere else, so this chip is the
        // only thing carrying it. Comfortable rows say it in text too, and
        // hearing it twice there beats not hearing it at all in compact.
        .accessibilityLabel(tool.label)
    }
}

/// Loads bundled provider logomark SVGs as template NSImages (macOS decodes
/// SVG natively and keeps it vector, so chips stay crisp at any size).
@MainActor
enum ProviderLogo {
    private static var cache: [String: NSImage] = [:]

    static func image(for tool: AgentTool) -> NSImage? {
        guard let name = tool.logoResource else { return nil }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
