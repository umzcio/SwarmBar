import SwiftUI

/// The request an approval row answers. What is shown, and whether that is
/// all of it, is decided by ApprovalPreviewText; this only lays it out.
/// A cut request is always marked, keeps its full text in the tooltip, and
/// expands in place to the whole thing, so nothing Approve allows is out of
/// reach of the row that offers it.
struct CommandPreview: View {
    let prompt: ApprovalPrompt

    @Environment(\.colorScheme) private var colorScheme
    @State private var expanded = false

    /// Longest text put in a tooltip. Past it the tooltip points at the
    /// expander, which has no limit.
    private static let tooltipLimit = 2_000

    // The prototype's near-black well only works over dark material; in
    // light mode a semantic fill keeps the amber text legible.
    private var well: AnyShapeStyle {
        colorScheme == .dark
            ? AnyShapeStyle(.black.opacity(0.25))
            : AnyShapeStyle(.quaternary)
    }

    var body: some View {
        Group {
            switch prompt.fidelity {
            case .exact:
                exact
            case .unreadable(let reason):
                unreadable(reason)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(well, in: .rect(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.orange.opacity(0.25))
        )
        // Nothing drawn for the request may reach past its well: stacked
        // marks that survive `visible` would otherwise paint over the
        // buttons and rows around it.
        .clipShape(.rect(cornerRadius: 7))
    }

    @ViewBuilder private var exact: some View {
        let collapsed = ApprovalPreviewText.collapsed(prompt.text)
        let full = ApprovalPreviewText.visible(prompt.text)
        VStack(alignment: .leading, spacing: 4) {
            if expanded && collapsed.isCut {
                ScrollView {
                    Text("$ \(full)")
                        .swarmFont(.mono)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            } else {
                // No line limit: the collapsed text is already cut where
                // ApprovalPreviewText decided, and SwiftUI must not cut it
                // again somewhere unmarked.
                Text("$ \(collapsed.text)\(collapsed.isCut ? "…" : "")")
                    .swarmFont(.mono)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if collapsed.isCut {
                Button(expanded ? "Show less" : ApprovalPreviewText.revealLabel(for: collapsed)) {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .swarmFont(.meta)
                .foregroundStyle(.orange)
            }
        }
        .help(collapsed.isCut
            ? (full.unicodeScalars.count <= Self.tooltipLimit ? full : "Show all to review the full request")
            : "")
    }

    private func unreadable(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reason)
                .swarmFont(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !prompt.text.isEmpty {
                // The agent's own words, labeled as such and never styled
                // as a command: they are what the agent says it is doing,
                // not what Approve would allow.
                Text("Agent's description: \(ApprovalPreviewText.visible(prompt.text))")
                    .swarmFont(.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}
