import AppKit
import SwiftUI

// MARK: - Opening the window

/// Holds the wizard's one model for the life of the app, and the latest
/// request to open it. The model is built on first use, so a user who never
/// opens the wizard never reads the bundled helper or builds the services.
@MainActor @Observable
final class RemoteWizardLauncher {
    static let windowID = "remote-hosts-wizard"

    struct Request: Equatable {
        let id = UUID()
        let entry: RemoteWizardModel.Entry
    }

    /// The newest request. It is never cleared, because the window keys its
    /// task on it and a change would restart that task; `takeRequest` marks
    /// it handled instead.
    private(set) var request: Request?
    @ObservationIgnored private var handled: UUID?
    @ObservationIgnored private var built: RemoteWizardModel?
    @ObservationIgnored private let makeModel: (@MainActor () -> RemoteWizardModel)?

    /// nil `makeModel` is demo mode, which has no remote hosts.
    init(makeModel: (@MainActor () -> RemoteWizardModel)?) {
        self.makeModel = makeModel
    }

    var model: RemoteWizardModel? {
        if built == nil { built = makeModel?() }
        return built
    }

    func ask(_ entry: RemoteWizardModel.Entry) {
        request = Request(entry: entry)
    }

    /// The request the window has not acted on yet, once.
    func takeRequest() -> RemoteWizardModel.Entry? {
        guard let request, request.id != handled else { return nil }
        handled = request.id
        return request.entry
    }
}

/// Opens the wizard fresh, or at step 3 for one host from Settings. Agent
/// apps are never frontmost on their own, so it activates the app too, or
/// the window would open behind whatever the user is in.
struct OpenRemoteWizardAction: Sendable {
    let perform: @MainActor @Sendable (RemoteWizardModel.Entry) -> Void

    @MainActor func callAsFunction(_ entry: RemoteWizardModel.Entry = .fresh) {
        perform(entry)
    }
}

extension EnvironmentValues {
    /// A no-op until `remoteWizardLauncher(_:)` provides the real one.
    @Entry var openRemoteWizard = OpenRemoteWizardAction { _ in }
}

extension View {
    /// Makes `openRemoteWizard` open this launcher's window.
    func remoteWizardLauncher(_ launcher: RemoteWizardLauncher) -> some View {
        modifier(ProvidesRemoteWizard(launcher: launcher))
    }
}

private struct ProvidesRemoteWizard: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let launcher: RemoteWizardLauncher

    func body(content: Content) -> some View {
        content.environment(\.openRemoteWizard, OpenRemoteWizardAction { [openWindow, launcher] entry in
            launcher.ask(entry)
            openWindow(id: RemoteWizardLauncher.windowID)
            NSApp.activate()
        })
    }
}

/// The Window scene's content. Acts on each open request once, and stops
/// every probe when the window closes.
struct RemoteWizardWindow: View {
    let launcher: RemoteWizardLauncher
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let model = launcher.model {
            RemoteWizardView(model: model) { dismissWindow(id: RemoteWizardLauncher.windowID) }
                .task(id: launcher.request?.id) {
                    guard let entry = launcher.takeRequest() else { return }
                    await model.open(entry)
                }
                .onDisappear { model.cancel() }
        } else {
            Text("Remote hosts aren't available in demo mode.")
                .swarmFont(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - The steps

/// Switches on the model's step. Every step reads the model and calls its
/// actions; nothing here decides what happens next.
struct RemoteWizardView: View {
    let model: RemoteWizardModel
    let close: () -> Void

    var body: some View {
        Group {
            switch model.step {
            case .intro:
                WizardIntroStep(model: model, close: close)
            case .checking, .pick:
                WizardPickStep(model: model, back: back)
            case .setup(let index):
                WizardSetupStep(model: model, index: index, back: back)
            case .applying(let index):
                WizardProgressStep(model: model, index: index, back: back)
            case .done:
                WizardDoneStep(model: model, close: close)
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 560)
        .navigationTitle(title)
    }

    /// Opened from Settings there is no pick to go back to, so Back closes
    /// the window there.
    private func back() {
        if model.openedAtSetup { close() } else { model.back() }
    }

    private var title: String {
        switch model.step {
        case .setup, .applying:
            guard let alias = model.currentAlias else { return "Add remote hosts" }
            let name = model.rows.first { $0.id == alias }?.displayName ?? alias
            return model.mode == .undo ? "Undo changes on \(name)" : "Set up \(name)"
        default:
            return "Add remote hosts"
        }
    }
}

// MARK: - Shared pieces

/// A step's scrolling body over a fixed footer of buttons.
struct WizardScaffold<Content: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack(spacing: 8) { footer }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }
}

/// A step's title, with "1 of 4 hosts" on the right when there is a count.
struct WizardHeading: View {
    let title: String
    var crumbs: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .swarmFont(.title)
            Spacer(minLength: 12)
            if let crumbs {
                Text(crumbs)
                    .swarmFont(.meta)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// The wizard's secondary sentences, which wrap rather than truncate.
    func wizardMuted() -> some View {
        swarmFont(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Ready, Partial, Needs setup, Can't connect or Can't continue. On the
/// done step Ready is a check mark, as in the mockup.
struct WizardPill: View {
    let pill: RemoteWizardModel.Pill
    var checkForReady = false

    var body: some View {
        Group {
            if pill == .ready && checkForReady {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityLabel("Ready")
            } else {
                Text(label)
                    .swarmFont(.captionEmphasis)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .fixedSize()
    }

    private var label: String {
        switch pill {
        case .ready: "Ready"
        case .partial: "Partial"
        case .needsSetup: "Needs setup"
        case .cantConnect: "Can't connect"
        case .cantContinue: "Can't continue"
        }
    }

    private var tint: Color {
        switch pill {
        case .ready: .green
        case .partial: .blue
        case .needsSetup: .orange
        case .cantConnect, .cantContinue: .red
        }
    }
}

/// A monospaced block the user can select from, with a Copy button. Long
/// text scrolls inside the block rather than pushing the steps away.
struct WizardCodeBlock: View {
    let text: String
    /// What VoiceOver says for Copy, since every block's button reads the same.
    let copyLabel: String
    var maxHeight: CGFloat = 120
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ViewThatFits(in: .vertical) {
                code
                ScrollView { code }
            }
            .frame(maxHeight: maxHeight)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            }
            .controlSize(.small)
            .padding(6)
            .accessibilityLabel(copyLabel)
        }
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var code: some View {
        Text(verbatim: text)
            .swarmFont(.mono)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .padding(.trailing, 64)
    }
}

/// A tinted box for what must not be missed: the root warning, a problem
/// that stops a host, a ssh config file that could not be read.
struct WizardNotice: View {
    let text: String
    var tint: Color = .orange
    var symbol: String = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .swarmFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(tint == .orange ? "Warning: \(text)" : text)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// The planned changes, under a heading per tool.
struct WizardChangeList: View {
    let groups: [RemoteWizardModel.ChangeGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if groups.isEmpty {
                Text("Nothing to change on this host.")
                    .wizardMuted()
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: group.title)
                        .swarmFont(.metaEmphasis)
                        .foregroundStyle(.secondary)
                    ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(verbatim: line)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .swarmFont(.body)
                    }
                }
            }
        }
    }
}
