import SwiftUI

/// Comfortable: two-plus lines, inline approval card.
struct SessionRow: View {
    @Environment(SessionStore.self) private var store
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ToolChip(tool: session.tool, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.projectName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    ElapsedTimeText(since: session.startedAt)
                }
                HStack(spacing: 5) {
                    // Fresh identity per status kind restarts the pulse/blink
                    // loop; without it the repeatForever animation freezes
                    // when the status category changes.
                    StatusDot(status: session.status)
                        .id(session.status.label)
                    Text("\(session.status.label) · \(session.tool.label)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(session.status.tint)
                }

                switch session.status {
                case .waitingApproval(let command):
                    CommandPreview(command: command)
                    ApprovalActions(session: session)
                case .waitingInput(let prompt):
                    Text("\u{201C}\(prompt)\u{201D}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Reply…") { store.openForReply(session) }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.small)
                case .working(let activity), .runningTool(let activity):
                    Text(activity)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .done(let summary):
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
