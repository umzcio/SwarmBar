import SwiftUI

struct PopoverRootView: View {
    @Environment(SessionStore.self) private var store

    // MenuBarExtra windows size to their content's ideal height, which
    // collapses a ScrollView to zero; measure the content instead.
    @State private var contentHeight: CGFloat = 100

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader()

            ScrollView {
                VStack(spacing: 0) {
                    SessionSection(
                        title: "Needs you",
                        emphasis: .attention,
                        sessions: store.attention,
                        emptyText: "All agents running on their own 🐝"
                    )
                    Divider().padding(.top, 6)
                    SessionSection(
                        title: "Active",
                        emphasis: .normal,
                        sessions: store.active
                    )
                    Divider().padding(.top, 6)
                    SessionSection(
                        title: "Recent",
                        emphasis: .normal,
                        sessions: store.recent
                    )
                }
                .padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .frame(height: min(contentHeight, 480))

            PopoverFooter()
        }
        .frame(width: 380)
    }
}

struct PopoverHeader: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SwarmBar")
                    .font(.system(size: 14, weight: .bold))
                SummaryLine()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }
}

struct SummaryLine: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        summary
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private var summary: Text {
        let base = Text("\(store.sessions.count) sessions · ")
        if store.attentionCount > 0 {
            let word = store.attentionCount == 1 ? "needs" : "need"
            return base + Text("\(store.attentionCount) \(word) you")
                .foregroundStyle(.orange)
                .fontWeight(.semibold)
        }
        return base + Text("\(store.active.count) active")
    }
}

struct PopoverFooter: View {
    var body: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider() }
    }
}
