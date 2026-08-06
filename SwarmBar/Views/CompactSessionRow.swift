import SwiftUI

/// Compact: everything on one ~28pt line.
struct CompactSessionRow: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.swarmScale) private var scale
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: session.status)
                .id(session.status.label)
            ToolChip(tool: session.tool, size: 18 * scale)
            Text(session.projectName)
                .swarmFont(.rowTitleCompact)
                .lineLimit(1)
                .frame(maxWidth: 118 * scale, alignment: .leading)

            Group {
                switch session.status {
                case .waitingApproval(let command):
                    Text("$ \(command)")
                        .swarmFont(.monoCompact)
                        .foregroundStyle(.orange)
                case .waitingInput(let prompt):
                    Text(prompt.isEmpty ? "Waiting on you" : "\u{201C}\(prompt)\u{201D}")
                        .foregroundStyle(.blue)
                case .working(let activity), .runningTool(let activity):
                    Text(activity)
                        .foregroundStyle(.tertiary)
                case .done(let summary):
                    Text(summary)
                        .foregroundStyle(.tertiary)
                case .idle:
                    Text("")
                }
            }
            .swarmFont(.detail)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .waitingApproval = session.status {
                MicroButton(.approve, help: "Approve") { store.approve(session) }
                MicroButton(.deny, help: "Deny") { store.deny(session) }
            }
            if case .waitingInput = session.status {
                MicroButton(.reply, help: "Reply") { store.replyingTo = session.id }
                MicroButton(.dismiss, help: "Dismiss") { store.acknowledge(session) }
            }
            // A finished turn whose process is still up can be steered.
            if case .done = session.status, session.processAlive {
                MicroButton(.reply, help: "Reply") { store.replyingTo = session.id }
            }

            ElapsedTimeText(since: session.elapsedAnchor, ago: session.status.timerReadsAgo)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(.rect(cornerRadius: 9))
        .hoverHighlight()
        .help(session.projectName)
        .sessionContextMenu(session, store: store)
    }
}

struct MicroButton: View {
    @Environment(\.swarmScale) private var scale

    enum Kind {
        case approve, deny, reply, dismiss

        var symbol: String {
            switch self {
            case .approve: "checkmark"
            case .deny:    "xmark"
            case .reply:   "arrowshape.turn.up.left"
            case .dismiss: "checkmark"
            }
        }
    }

    let kind: Kind
    let help: String
    let action: () -> Void

    init(_ kind: Kind, help: String, action: @escaping () -> Void) {
        self.kind = kind
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.symbol)
                .swarmFont(.iconSmall)
                .foregroundStyle(foreground)
                .frame(width: 20 * scale, height: 20 * scale)
                .background(background, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .approve: AnyShapeStyle(.black.opacity(0.85))
        case .deny:    AnyShapeStyle(.primary)
        case .reply:   AnyShapeStyle(.white)
        case .dismiss: AnyShapeStyle(.primary)
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .approve: AnyShapeStyle(.orange)
        case .deny:    AnyShapeStyle(.primary.opacity(0.12))
        case .reply:   AnyShapeStyle(.blue)
        case .dismiss: AnyShapeStyle(.primary.opacity(0.12))
        }
    }
}
