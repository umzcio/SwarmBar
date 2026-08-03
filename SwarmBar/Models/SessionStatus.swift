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
}
