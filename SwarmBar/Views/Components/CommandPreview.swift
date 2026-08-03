import SwiftUI

struct CommandPreview: View {
    let command: String

    var body: some View {
        Text("$ \(command)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.25), in: .rect(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.orange.opacity(0.25))
            )
    }
}
