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
    /// The tool's own name for this session, when it has one. Kimi and
    /// BearCode put `sessionTitle` on every hook payload. Several rows
    /// often share a project name, so this is what tells them apart.
    /// Shown as the row's tooltip rather than replacing the project name,
    /// which is the label the prototype specifies.
    var title: String?
    /// Whether the tool's process still runs. A live session that just
    /// finished a turn belongs in Active, not buried in Recent history.
    var processAlive: Bool
    /// Which host this session runs on. Nil means this Mac. Remote and
    /// local rows of the same tool must never delete each other during
    /// sync, and two hosts can legitimately hold the same session id if a
    /// home directory is copied between them.
    var host: String?
    /// Identity of the request itself, independent of transcript mtime.
    /// Nil for providers that only expose a status snapshot.
    var attentionEventID: String?

    /// This session under another id and host. `id` is a constant, so the
    /// copy is rebuilt field by field, and it lives here beside the stored
    /// properties so a field added above is added below in the same edit.
    /// Remote discovery uses it to scope a tool's own id to its host.
    func withID(_ id: UUID, host: String?) -> AgentSession {
        AgentSession(
            id: id,
            tool: tool,
            projectName: projectName,
            projectPath: projectPath,
            status: status,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            pid: pid,
            accountLabel: accountLabel,
            title: title,
            processAlive: processAlive,
            host: host,
            attentionEventID: attentionEventID)
    }

    init(
        id: UUID = UUID(),
        tool: AgentTool,
        projectName: String,
        projectPath: URL? = nil,
        status: SessionStatus,
        startedAt: Date = .now,
        lastActivityAt: Date? = nil,
        pid: pid_t? = nil,
        accountLabel: String? = nil,
        title: String? = nil,
        processAlive: Bool = false,
        host: String? = nil,
        attentionEventID: String? = nil
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
        self.title = title
        self.processAlive = processAlive
        self.host = host
        self.attentionEventID = attentionEventID
    }

    /// What the row's elapsed timer should measure: run length while
    /// active, waiting time otherwise.
    var elapsedAnchor: Date {
        status.isActive ? startedAt : lastActivityAt
    }
}
