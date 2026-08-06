import SwiftUI

struct CommandPreview: View {
    let command: String

    @Environment(\.colorScheme) private var colorScheme

    // The prototype's near-black well only works over dark material; in
    // light mode a semantic fill keeps the amber text legible.
    private var well: AnyShapeStyle {
        colorScheme == .dark
            ? AnyShapeStyle(.black.opacity(0.25))
            : AnyShapeStyle(.quaternary)
    }

    var body: some View {
        Text("$ \(command)")
            .swarmFont(.mono)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(well, in: .rect(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.orange.opacity(0.25))
            )
    }
}
