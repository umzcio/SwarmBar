import SwiftUI

struct ToolChip: View {
    let tool: AgentTool
    let size: CGFloat

    var body: some View {
        Text(tool.glyph)
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tool.tint.gradient, in: .rect(cornerRadius: size * 0.27))
            .help(tool.label)
    }
}
