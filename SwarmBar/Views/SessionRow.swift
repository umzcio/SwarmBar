import SwiftUI

/// Comfortable: two-plus lines, inline approval card.
struct SessionRow: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.swarmScale) private var scale
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ToolChip(tool: session.tool, size: 26 * scale)
                .doubleClickOpensTerminal(session, store: store)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.projectName)
                        .swarmFont(.rowTitleStrong)
                        .lineLimit(1)
                    Spacer()
                    ElapsedTimeText(since: session.elapsedAnchor, ago: session.status.timerReadsAgo)
                }
                .doubleClickOpensTerminal(session, store: store)
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
                    Spacer(minLength: 0)
                }
                .doubleClickOpensTerminal(session, store: store)

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
        // The project name stays the row's label, as the prototype
        // specifies. The tool's own title for the session goes here, where
        // it disambiguates several rows sharing one project without
        // changing the layout.
        .help(session.title ?? session.projectName)
        .sessionRowInteractions(session, store: store)
    }
}

extension View {
    /// The context menu, applied to the whole row in both densities.
    func sessionRowInteractions(_ session: AgentSession, store: SessionStore) -> some View {
        modifier(SessionRowInteractions(session: session, store: store))
    }

    /// The double-click shortcut to a session's terminal.
    ///
    /// Deliberately NOT applied to the whole row. A row sets
    /// `contentShape(.rect)` so its hover highlight and context menu cover
    /// the full area, which makes the row one hit-test surface sitting in
    /// front of its own buttons. A tap recognizer attached there intercepts
    /// clicks meant for Approve and Deny, and the row needed two or three
    /// clicks to respond. Attaching it behind the content does not help
    /// either: the content shape absorbs the hit first.
    ///
    /// So it goes on the identity area only, the chip and the text, which
    /// have no controls in them. Approve, Deny, Reply and Dismiss are
    /// siblings of that area and never see this gesture.
    func doubleClickOpensTerminal(_ session: AgentSession, store: SessionStore) -> some View {
        modifier(DoubleClickToOpen(session: session, store: store))
    }
}

/// The part of a row's interaction rules that can be tested without a
/// running UI.
///
/// What CANNOT be tested here, and is therefore a manual check (see
/// HANDOFF.md, "Row interactions"): that the row's own buttons win a
/// click over the double-click gesture. SwiftUI renders the whole row into
/// one NSView, its accessibility children do not surface in process, and
/// hitTest cannot tell a button click from a row click, so no in-process
/// test can observe which one wins. Do not add a test that claims to.
enum SessionRowInteraction {
    /// A double-click recognizer is attached only when it could actually
    /// fire. Attaching it always and returning early inside the handler
    /// looks equivalent and is not: the recognizer still makes every
    /// single click wait to see whether a second one follows.
    static func attachesDoubleClick(enabled: Bool, hasProjectPath: Bool) -> Bool {
        enabled && hasProjectPath
    }
}

private struct SessionRowInteractions: ViewModifier {
    let session: AgentSession
    let store: SessionStore

    private var canOpen: Bool { session.projectPath != nil }

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open in Terminal") { store.openInTerminal(session) }
                .disabled(!canOpen)
            Button("Copy project path") { store.copyProjectPath(session) }
                .disabled(!canOpen)
        }
    }
}

private struct DoubleClickToOpen: ViewModifier {
    @AppStorage("doubleClickOpensTerminal") private var enabled = true
    let session: AgentSession
    let store: SessionStore

    func body(content: Content) -> some View {
        if SessionRowInteraction.attachesDoubleClick(
            enabled: enabled, hasProjectPath: session.projectPath != nil) {
            // Attached only when it could fire. A recognizer that will
            // never fire still makes every single click here wait to see
            // whether a second one follows.
            content
                .contentShape(.rect)
                .onTapGesture(count: 2) { store.openInTerminal(session) }
        } else {
            content
        }
    }
}
