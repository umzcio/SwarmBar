import SwiftUI

enum SessionStatus: Equatable, Sendable {
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

    /// Classifies a finished turn: a message that asks something is
    /// waiting on the user, a plain report is done. The full text decides
    /// (questions often sit in the last paragraph), the preview is shown.
    /// Empty text stays waiting, since there is nothing to classify.
    static func finishedTurn(fullText: String, preview: String) -> SessionStatus {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .waitingInput(prompt: preview) }
        return trimmed.contains("?")
            ? .waitingInput(prompt: preview)
            : .done(summary: preview)
    }
}
