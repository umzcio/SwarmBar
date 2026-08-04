import SwiftUI

/// The drill-in reply surface. Replaces the popover's session list while
/// open, so writing a reply stays in one window instead of opening a second.
struct ReplyComposer: View {
    @Environment(SessionStore.self) private var store
    let session: AgentSession
    let onClose: () -> Void

    @State private var text = ""
    @State private var error: String?
    @State private var sending = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            question
            editor
            footer
        }
        .frame(width: 380)
        .onAppear { editorFocused = true }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back")

            ToolChip(tool: session.tool, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("Reply to \(session.tool.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// What the agent last said, so the reply has its question in view.
    @ViewBuilder
    private var question: some View {
        let asked: String? = {
            switch session.status {
            case .waitingInput(let prompt): prompt.isEmpty ? nil : prompt
            case .done(let summary):        summary.isEmpty ? nil : summary
            default:                        nil
            }
        }()
        if let asked {
            Text("\u{201C}\(asked)\u{201D}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .frame(height: 120)
            .padding(6)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .focused($editorFocused)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .disabled(sending)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Return adds a line, Command Return sends")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 11)
    }

    private var canSend: Bool {
        !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        sending = true
        error = nil
        store.sendReply(session, text: text) { result in
            sending = false
            switch result {
            case .sent:
                onClose()
            case .failed(let message):
                // The draft is never discarded on failure; it is the only
                // copy of what the user wrote.
                error = message
            }
        }
    }
}
