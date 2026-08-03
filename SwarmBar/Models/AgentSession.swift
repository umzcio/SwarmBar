import Foundation

struct AgentSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let tool: AgentTool
    let projectName: String       // e.g. repo dir basename
    let projectPath: URL?         // for "Open in Terminal"
    var status: SessionStatus
    var startedAt: Date
    var lastActivityAt: Date      // resumed sessions can be weeks old; rows
                                  // show this for waiting/idle states
    var pid: pid_t?               // liveness checks
    var accountLabel: String?     // e.g. GMAIL / TEAM / CIO, from hook env

    init(
        id: UUID = UUID(),
        tool: AgentTool,
        projectName: String,
        projectPath: URL? = nil,
        status: SessionStatus,
        startedAt: Date = .now,
        lastActivityAt: Date? = nil,
        pid: pid_t? = nil,
        accountLabel: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.projectName = projectName
        self.projectPath = projectPath
        self.status = status
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
        self.pid = pid
        self.accountLabel = accountLabel
    }

    /// What the row's elapsed timer should measure: run length while
    /// active, waiting time otherwise.
    var elapsedAnchor: Date {
        status.isActive ? startedAt : lastActivityAt
    }
}
