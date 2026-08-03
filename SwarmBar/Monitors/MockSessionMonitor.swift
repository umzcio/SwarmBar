import Foundation

/// Replays the HTML prototype's simulation: seeded sessions across all three
/// tools, random status transitions every few seconds, approvals appearing,
/// sessions completing, and the occasional new session spinning up.
@MainActor
struct MockSessionMonitor: SessionMonitor {
    private static let workActivities = [
        "Thinking through the refactor…",
        "Editing SessionMonitor.swift",
        "Reading StatusBarController.swift",
        "Planning next steps…",
        "Writing unit tests…",
        "Reviewing diff before commit…",
    ]
    private static let toolActivities = [
        "Running swift build",
        "Running swift test",
        "Grepping for NSStatusItem",
        "Running git diff --stat",
        "Fetching docs page…",
    ]
    private static let approvalCommands = [
        "rm -rf DerivedData/",
        "git push origin main",
        "brew install swiftlint",
        "npm install -g @anthropic-ai/claude-code",
        "curl -sL https://example.com/install.sh | sh",
    ]
    private static let inputPrompts = [
        "Should the popover pin on click or hover?",
        "Two approaches to the state machine, which do you prefer?",
        "Ready to commit 4 files. Message okay?",
    ]
    private static let newProjectNames = [
        "bearcode", "unifyit", "range-notes", "homelab-scripts", "spendit",
    ]

    func start(into store: SessionStore) async {
        seed(into: store)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3.5))
            guard !store.isPaused else { continue }
            step(store)
        }
    }

    private func seed(into store: SessionStore) {
        let seeded: [AgentSession] = [
            AgentSession(tool: .claudeCode, projectName: "swarmbar · main",
                         status: .working(activity: Self.workActivities[1]),
                         startedAt: .now.addingTimeInterval(-8 * 60)),
            AgentSession(tool: .claudeCode, projectName: "muren-site",
                         status: .runningTool(activity: Self.toolActivities[0]),
                         startedAt: .now.addingTimeInterval(-22 * 60)),
            AgentSession(tool: .codex, projectName: "docuridge",
                         status: .working(activity: Self.workActivities[4]),
                         startedAt: .now.addingTimeInterval(-3 * 60)),
            AgentSession(tool: .kimiCode, projectName: "curbdot",
                         status: .waitingInput(prompt: Self.inputPrompts[0]),
                         startedAt: .now.addingTimeInterval(-14 * 60)),
            AgentSession(tool: .codex, projectName: "ficino",
                         status: .done(summary: "Merged PR #42 · 12 files"),
                         startedAt: .now.addingTimeInterval(-41 * 60)),
            AgentSession(tool: .claudeCode, projectName: "aif-scanner",
                         status: .waitingApproval(command: Self.approvalCommands[0]),
                         startedAt: .now.addingTimeInterval(-5 * 60)),
            AgentSession(tool: .openCode, projectName: "range-notes",
                         status: .working(activity: Self.workActivities[5]),
                         startedAt: .now.addingTimeInterval(-11 * 60)),
            AgentSession(tool: .grokBuild, projectName: "spendit",
                         status: .runningTool(activity: Self.toolActivities[3]),
                         startedAt: .now.addingTimeInterval(-2 * 60)),
        ]
        for session in seeded.reversed() { store.upsert(session) }
    }

    private func step(_ store: SessionStore) {
        guard let session = store.sessions.randomElement() else { return }
        let roll = Double.random(in: 0..<1)

        switch session.status {
        case .working:
            if roll < 0.35 {
                store.update(id: session.id) {
                    $0.status = .runningTool(activity: Self.toolActivities.randomElement()!)
                }
            } else if roll < 0.45 {
                store.update(id: session.id) {
                    $0.status = .waitingApproval(command: Self.approvalCommands.randomElement()!)
                }
            } else if roll < 0.52 {
                store.update(id: session.id) {
                    $0.status = .waitingInput(prompt: Self.inputPrompts.randomElement()!)
                }
            } else if roll < 0.58 {
                let files = Int.random(in: 2...15)
                store.update(id: session.id) {
                    $0.status = .done(summary: "Task complete · \(files) files changed")
                }
            } else {
                store.update(id: session.id) {
                    $0.status = .working(activity: Self.workActivities.randomElement()!)
                }
            }
        case .runningTool:
            if roll < 0.6 {
                store.update(id: session.id) {
                    $0.status = .working(activity: Self.workActivities.randomElement()!)
                }
            } else {
                store.update(id: session.id) {
                    $0.status = .runningTool(activity: Self.toolActivities.randomElement()!)
                }
            }
        case .done where roll < 0.12 && store.sessions.count < 8:
            // A new session spins up now and then.
            store.upsert(AgentSession(
                tool: AgentTool.allCases.randomElement()!,
                projectName: Self.newProjectNames.randomElement()!,
                status: .working(activity: Self.workActivities.randomElement()!)
            ))
        default:
            break
        }
    }
}
