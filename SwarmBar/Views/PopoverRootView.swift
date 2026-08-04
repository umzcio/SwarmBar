import ServiceManagement
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
                    if store.visibleCount == 0 {
                        Text("No agent sessions")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        if !store.attention.isEmpty {
                            SessionSection(
                                title: "Needs you",
                                emphasis: .attention,
                                sessions: store.attention
                            )
                        }
                        if !store.active.isEmpty {
                            if !store.attention.isEmpty { Divider().padding(.top, 6) }
                            SessionSection(
                                title: "Active",
                                emphasis: .normal,
                                sessions: store.active
                            )
                        }
                        if !store.recent.isEmpty {
                            if !store.attention.isEmpty || !store.active.isEmpty {
                                Divider().padding(.top, 6)
                            }
                            SessionSection(
                                title: "Recent",
                                emphasis: .normal,
                                sessions: store.recent
                            )
                        }
                    }
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
    @Environment(SessionStore.self) private var store
    @AppStorage("compactRows") private var compact = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SwarmBar")
                    .font(.system(size: 14, weight: .bold))
                SummaryLine()
            }
            Spacer()
            HStack(spacing: 4) {
                HeaderIconButton(
                    symbol: "list.dash",
                    active: compact,
                    help: compact ? "Comfortable view" : "Compact view"
                ) { compact.toggle() }
                HeaderIconButton(
                    symbol: store.isPaused ? "play.fill" : "pause.fill",
                    tint: store.isPaused ? .orange : nil,
                    help: store.isPaused ? "Resume all agents" : "Pause all agents"
                ) { store.pauseAll() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }
}

struct HeaderIconButton: View {
    let symbol: String
    var active: Bool = false
    var tint: Color? = nil
    let help: String
    let action: () -> Void

    init(symbol: String, active: Bool = false, tint: Color? = nil,
         help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.active = active
        self.tint = tint
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init)
                                 ?? (active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .frame(width: 26, height: 26)
                .background(.primary.opacity(active ? 0.14 : 0),
                            in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SummaryLine: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        summary
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var summary: Text {
        let count = store.visibleCount
        let base = Text("\(count) session\(count == 1 ? "" : "s") · ")
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
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Button {
                openSettings()
                NSApp.activate()
                // The Settings scene restores its last frame, which can be
                // anywhere (including where UI automation once dragged it);
                // a menu bar app's settings should just open centered.
                DispatchQueue.main.async {
                    NSApp.windows
                        .first { $0.identifier?.rawValue.contains("Settings") == true }?
                        .center()
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider() }
    }
}
