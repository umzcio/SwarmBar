import Foundation

struct AgentSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let tool: AgentTool
    let projectName: String       // e.g. repo dir basename
    let projectPath: URL?         // for "Open in Terminal"
    var status: SessionStatus
    var startedAt: Date
    var pid: pid_t?               // liveness checks

    init(
        id: UUID = UUID(),
        tool: AgentTool,
        projectName: String,
        projectPath: URL? = nil,
        status: SessionStatus,
        startedAt: Date = .now,
        pid: pid_t? = nil
    ) {
        self.id = id
        self.tool = tool
        self.projectName = projectName
        self.projectPath = projectPath
        self.status = status
        self.startedAt = startedAt
        self.pid = pid
    }
}
