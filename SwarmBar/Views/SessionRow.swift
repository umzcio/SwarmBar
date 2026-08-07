import SwiftUI

/// Comfortable: two-plus lines, inline approval card.
struct SessionRow: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.swarmScale) private var scale
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ToolChip(tool: session.tool, size: 26 * scale)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.projectName)
                        .swarmFont(.rowTitleStrong)
                        .lineLimit(1)
                    Spacer()
                    ElapsedTimeText(since: session.elapsedAnchor, ago: session.status.timerReadsAgo)
                }
                HStack(spacing: 5) {
                    // Fresh identity per status kind restarts the pulse/blink
                    // loop; without it the repeatForever animation freezes
                    // when the status category changes.
                    StatusDot(status: session.status)
                        .id(session.status.label)
                    Text("\(session.status.label) · \(session.tool.label)")
                        .swarmFont(.metaEmphasis)
                        .foregroundStyle(session.status.tint)
                    if let account = session.accountLabel {
                        Text(account)
                            .swarmFont(.captionEmphasis)
                            .foregroundStyle(.tertiary)
                    }
                }

                switch session.status {
                case .waitingApproval(let command):
                    CommandPreview(command: command)
                    ApprovalActions(session: session)
                case .waitingInput(let prompt):
                    if !prompt.isEmpty {
                        Text("\u{201C}\(prompt)\u{201D}")
                            .swarmFont(.body)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Button("Reply…") { store.replyingTo = session.id }
                            .buttonStyle(ActionPill.reply)
                            .accessibilityLabel("Reply")
                        Button("Dismiss") { store.acknowledge(session) }
                            .buttonStyle(ActionPill.deny)
                            .accessibilityLabel("Dismiss")
                    }
                case .working(let activity), .runningTool(let activity):
                    Text(activity)
                        .swarmFont(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .done(let summary):
                    Text(summary)
                        .swarmFont(.body)
                        .foregroundStyle(.secondary)
                    // A finished turn is still steerable: its composer is
                    // idle, so a reply can start the next turn.
                    if session.processAlive {
                        Button("Reply…") { store.replyingTo = session.id }
                            .buttonStyle(ActionPill.reply)
                            .accessibilityLabel("Reply")
                    }
                case .idle:
                    EmptyView()
                }
            }
        }
        .padding(8)
        .contentShape(.rect(cornerRadius: 9))
        .hoverHighlight()
        .sessionRowInteractions(session, store: store)
    }
}

extension View {
    /// The interactions a session row offers whatever its density: the
    /// context menu, and the optional double-click shortcut to its
    /// terminal. Both rows apply this, so the two densities cannot drift.
    func sessionRowInteractions(_ session: AgentSession, store: SessionStore) -> some View {
        modifier(SessionRowInteractions(session: session, store: store))
    }
}

private struct SessionRowInteractions: ViewModifier {
    @AppStorage("doubleClickOpensTerminal") private var doubleClickOpens = true
    let session: AgentSession
    let store: SessionStore

    private var canOpen: Bool { session.projectPath != nil }

    func body(content: Content) -> some View {
        menu(content)
            // Attached only when it can actually do something, rather than
            // attached always and guarded inside. A double-click recognizer
            // that is never going to fire still costs every single click a
            // disambiguation delay, and the row's buttons are clicked far
            // more often than its background.
            .modifier(DoubleClickToOpen(
                enabled: doubleClickOpens && canOpen,
                action: { store.openInTerminal(session) }
            ))
    }

    private func menu(_ content: Content) -> some View {
        content.contextMenu {
            Button("Open in Terminal") { store.openInTerminal(session) }
                .disabled(!canOpen)
            Button("Copy project path") { store.copyProjectPath(session) }
                .disabled(!canOpen)
        }
    }
}

private struct DoubleClickToOpen: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            // Not simultaneousGesture: the row's own buttons must win the
            // click. Approve and Deny sit inside this hit area, and double
            // clicking Approve must approve once, not also open a terminal.
            content.onTapGesture(count: 2, perform: action)
        } else {
            content
        }
    }
}
