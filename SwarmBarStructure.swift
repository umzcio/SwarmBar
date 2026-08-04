//
//  SwarmBar, phase 1 structure sketch (SUPERSEDED)
//
//  This file is the original single-file architecture sketch. It is not
//  compiled and it is NOT a description of the current app. It is kept as
//  a record of the starting shape.
//
//  Do not "fill in its stubs". Where it disagrees with the code, the code
//  is right. Known divergences as of commit 0cc0b66:
//
//    - AgentTool here has three cases; the app has six (adds bearCode,
//      openCode, grokBuild). See SwarmBar/Models/AgentTool.swift.
//    - `recent` here is simply "not attention and not active". The app
//      adds a one hour retention window and collapses launch-scoped tool
//      trails per project. See SwarmBar/Store/SessionStore.swift.
//    - Density lives in @AppStorage("compactRows") read by the views, not
//      on the store.
//    - MenuBarLabel takes no parameters; it reads the store from the
//      environment and renders pre-cached glyph frames.
//    - Whole subsystems are absent here: HookServer, TerminalFocuser,
//      ProcessLiveness, TuiPromptLayout, StableID, every parser, and the
//      Settings/ directory.
//
//  For the current architecture and its rules, read CLAUDE.md.
//

import SwiftUI

// MARK: - Models -----------------------------------------------------------

// SUPERSEDED: the app has six cases. See SwarmBar/Models/AgentTool.swift.
enum AgentTool: String, CaseIterable, Identifiable {
    case claudeCode, codex, kimiCode
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex:      "Codex"
        case .kimiCode:   "Kimi Code"
        }
    }
    var glyph: String {
        switch self {
        case .claudeCode: "✳︎"
        case .codex:      "◎"
        case .kimiCode:   "K"
        }
    }
    var tint: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:      Color(red: 0.10, green: 0.76, blue: 0.72)
        case .kimiCode:   Color(red: 0.30, green: 0.55, blue: 1.00)
        }
    }
}

enum SessionStatus: Equatable {
    case working(activity: String)
    case runningTool(activity: String)
    case waitingApproval(command: String)
    case waitingInput(prompt: String)
    case idle
    case done(summary: String)

    /// Drives the three popover sections.
    var needsAttention: Bool {
        switch self {
        case .waitingApproval, .waitingInput: true
        default: false
        }
    }
    var isActive: Bool {
        switch self {
        case .working, .runningTool: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .working:         "Working"
        case .runningTool:     "Running tool"
        case .waitingApproval: "Approval"
        case .waitingInput:    "Waiting on you"
        case .idle:            "Idle"
        case .done:            "Done"
        }
    }
    var tint: Color {
        switch self {
        case .working:         .green
        case .runningTool:     .purple
        case .waitingApproval: .orange
        case .waitingInput:    .blue
        case .idle:            .gray
        case .done:            .green
        }
    }
    var pulses: Bool { isActive }
    var blinks: Bool { needsAttention }
}

struct AgentSession: Identifiable, Equatable {
    let id: UUID
    let tool: AgentTool
    let projectName: String       // e.g. repo dir basename
    let projectPath: URL?         // for "Open in Terminal"
    var status: SessionStatus
    var startedAt: Date
    var pid: pid_t?               // liveness checks
}

// MARK: - Store ------------------------------------------------------------

/// Single source of truth. Monitors push updates in; views observe.
@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []
    var isPaused = false

    // Density preference persists across launches.
    // (@AppStorage doesn't work directly inside @Observable —
    //  wrap UserDefaults manually or keep it in the view layer.)
    // SUPERSEDED: density is @AppStorage("compactRows"), read in the views.
    var isCompact: Bool {
        get { UserDefaults.standard.bool(forKey: "compactRows") }
        set { UserDefaults.standard.set(newValue, forKey: "compactRows") }
    }

    // Derived slices the popover renders.
    var attention: [AgentSession] { sessions.filter { $0.status.needsAttention } }
    var active:    [AgentSession] { sessions.filter { $0.status.isActive } }
    // SUPERSEDED: the app adds retention and launch-scoped collapsing.
    var recent:    [AgentSession] { sessions.filter { !$0.status.needsAttention && !$0.status.isActive } }

    var anyActive: Bool { !active.isEmpty }
    var attentionCount: Int { attention.count }

    // Called by monitors (on MainActor).
    func upsert(_ session: AgentSession) { /* merge by id, keep startedAt */ }
    func remove(id: UUID) { /* session process exited */ }

    // Called by row buttons. These write back to the tool's control
    // channel (e.g. answering the permission prompt via the session's
    // tty / IPC / hook response), then the monitor confirms the new state.
    func approve(_ session: AgentSession) { }
    func deny(_ session: AgentSession) { }
    func openForReply(_ session: AgentSession) { /* focus the terminal/tab */ }
    func pauseAll() { }
}

// MARK: - Monitors ---------------------------------------------------------

/// One conformer per tool. Each discovers live sessions and streams
/// status changes into the store.
protocol SessionMonitor {
    func start(into store: SessionStore) async
}

/// Claude Code: watch ~/.claude/projects/**/​*.jsonl with DispatchSource /
/// FSEventStream, parse the tail for the latest event type (assistant turn,
/// tool_use, permission request). Hooks (Notification / Stop / PreToolUse)
/// can also POST to a local socket for lower latency than file polling.
struct ClaudeCodeMonitor: SessionMonitor {
    func start(into store: SessionStore) async { }
}

struct CodexMonitor: SessionMonitor {
    func start(into store: SessionStore) async { }
}

struct KimiMonitor: SessionMonitor {
    func start(into store: SessionStore) async { }
}

// MARK: - App entry --------------------------------------------------------

@main
struct SwarmBarApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        // .window style = the rich popover from the prototype.
        // NOTE: MenuBarExtra labels are rendered as template images, so the
        // amber badge and the buzzing-dot animation from the prototype won't
        // render in color there. If you want the full animated icon + badge,
        // drop to AppKit: an NSStatusItem whose button hosts an
        // NSHostingView, and present the SwiftUI popover via NSPopover.
        // Start with MenuBarExtra; swap later only if the icon matters.
        MenuBarExtra {
            PopoverRootView()
                .environment(store)
        } label: {
            MenuBarLabel(
                anyActive: store.anyActive,
                attentionCount: store.attentionCount
            )
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar label ---------------------------------------------------

struct MenuBarLabel: View {
    let anyActive: Bool
    let attentionCount: Int

    var body: some View {
        // Template-image constraint: encode state in shape, not color.
        // e.g. swarm dots filled when active, hollow when idle, and the
        // count drawn into the symbol itself.
        Image(systemName: attentionCount > 0
              ? "circle.hexagongrid.fill"
              : "circle.hexagongrid")
        // Custom approach: render the 4-dot swarm to an NSImage with
        // isTemplate = true, regenerated on state change.
    }
}

// MARK: - Popover ----------------------------------------------------------

struct PopoverRootView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader()

            ScrollView {
                VStack(spacing: 0) {
                    SessionSection(
                        title: "Needs you",
                        emphasis: .attention,
                        sessions: store.attention,
                        emptyText: "All agents running on their own"
                    )
                    Divider().padding(.top, 6)
                    SessionSection(title: "Active",
                                   emphasis: .normal,
                                   sessions: store.active)
                    Divider().padding(.top, 6)
                    SessionSection(title: "Recent",
                                   emphasis: .normal,
                                   sessions: store.recent)
                }
            }
            .frame(maxHeight: 480)

            PopoverFooter()
        }
        .frame(width: 380)
        // Material background comes free with .window MenuBarExtra style;
        // otherwise: .background(.ultraThinMaterial)
    }
}

struct PopoverHeader: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("compactRows") private var compact = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SwarmBar").font(.system(size: 14, weight: .bold))
                SummaryLine() // "6 sessions · 2 need you"
            }
            Spacer()
            Toggle(isOn: $compact) { Image(systemName: "list.dash") }
                .toggleStyle(.button).buttonStyle(.borderless)
                .help(compact ? "Comfortable view" : "Compact view")
            Button { store.pauseAll() } label: {
                Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help("Pause all agents")
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct SummaryLine: View { var body: some View { EmptyView() } }

// MARK: - Sections & rows --------------------------------------------------

struct SessionSection: View {
    enum Emphasis { case normal, attention }

    let title: String
    let emphasis: Emphasis
    let sessions: [AgentSession]
    var emptyText: String? = nil

    @AppStorage("compactRows") private var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(emphasis == .attention ? .orange : .tertiary)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 5)

            if sessions.isEmpty, let emptyText {
                Text(emptyText)
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            }

            ForEach(sessions) { session in
                Group {
                    if compact { CompactSessionRow(session: session) }
                    else       { SessionRow(session: session) }
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: sessions.map(\.id))
    }
}

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
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    ElapsedTimeText(since: session.startedAt) // TimelineView(.periodic)
                }
                HStack(spacing: 5) {
                    StatusDot(status: session.status)
                    Text("\(session.status.label) · \(session.tool.label)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.status.tint)
                }

                switch session.status {
                case .waitingApproval(let command):
                    CommandPreview(command: command)   // mono, amber border
                    ApprovalActions(session: session)  // Approve / Deny
                case .waitingInput(let prompt):
                    Text("“\(prompt)”")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Reply…") { store.openForReply(session) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                case .working(let activity), .runningTool(let activity):
                    Text(activity)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1)
                case .done(let summary):
                    Text(summary)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
            }
        }
        .padding(8)
        .contentShape(.rect(cornerRadius: 9))
        .hoverHighlight() // custom modifier: subtle bg on hover
        .contextMenu {
            Button("Open in Terminal") { store.openForReply(session) }
            Button("Copy project path") { }
            Divider()
            Button("Stop session", role: .destructive) { }
        }
    }
}

/// Compact: everything on one ~28pt line.
struct CompactSessionRow: View {
    @Environment(SessionStore.self) private var store
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: session.status)
            ToolChip(tool: session.tool, size: 18)
            Text(session.projectName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 118, alignment: .leading)

            // Middle: truncating activity / command / prompt
            Group {
                switch session.status {
                case .waitingApproval(let command):
                    Text("$ \(command)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.orange)
                case .waitingInput(let prompt):
                    Text("“\(prompt)”").foregroundStyle(.blue)
                case .working(let a), .runningTool(let a):
                    Text(a).foregroundStyle(.tertiary)
                case .done(let s):
                    Text(s).foregroundStyle(.tertiary)
                case .idle:
                    Text("")
                }
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Inline micro-actions
            if case .waitingApproval = session.status {
                MicroButton("checkmark", tint: .orange) { store.approve(session) }
                MicroButton("xmark", tint: .gray) { store.deny(session) }
            }
            if case .waitingInput = session.status {
                MicroButton("arrowshape.turn.up.left", tint: .blue) {
                    store.openForReply(session)
                }
            }

            ElapsedTimeText(since: session.startedAt)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .contentShape(.rect(cornerRadius: 9))
        .hoverHighlight()
        .help(session.projectName) // full name on hover
    }
}

// MARK: - Components -------------------------------------------------------

struct StatusDot: View {
    let status: SessionStatus
    // Pulse/blink via .symbolEffect or a TimelineView-driven scale/opacity;
    // gate on \.accessibilityReduceMotion.
    var body: some View {
        Circle().fill(status.tint).frame(width: 7, height: 7)
    }
}

struct ToolChip: View {
    let tool: AgentTool
    let size: CGFloat
    var body: some View {
        Text(tool.glyph)
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tool.tint.gradient, in: .rect(cornerRadius: size * 0.27))
    }
}

struct ApprovalActions: View { let session: AgentSession; var body: some View { EmptyView() } }
struct CommandPreview: View { let command: String; var body: some View { EmptyView() } }
struct ElapsedTimeText: View { let since: Date; var body: some View { EmptyView() } }
struct MicroButton: View {
    init(_ symbol: String, tint: Color, action: @escaping () -> Void) { }
    var body: some View { EmptyView() }
}
struct PopoverFooter: View { var body: some View { EmptyView() } }

extension View {
    func hoverHighlight() -> some View { self } // onHover + RoundedRectangle fill
}
