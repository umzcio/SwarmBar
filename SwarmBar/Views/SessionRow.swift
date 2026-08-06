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
        .sessionContextMenu(session, store: store)
    }
}

extension View {
    func sessionContextMenu(_ session: AgentSession, store: SessionStore) -> some View {
        contextMenu {
            Button("Open in Terminal") { store.openInTerminal(session) }
                .disabled(session.projectPath == nil)
            Button("Copy project path") { store.copyProjectPath(session) }
                .disabled(session.projectPath == nil)
        }
    }
}
