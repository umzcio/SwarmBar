import Foundation

/// Grok Build: ~/.grok/active_sessions.json is a JSON array that, when
/// non-empty, names the sessions currently running (entries may carry a
/// session id under a few different key spellings, and/or a pid; the exact
/// shape wasn't pinned down, so lookup is defensive). Per-session state
/// lives under ~/.grok/sessions/<url-encoded-cwd>/<uuid>/summary.json plus
/// chat_history.jsonl. session_search.sqlite and any other stray file next
/// to the per-cwd directories is skipped by only descending into actual
/// directories.
struct GrokBuildMonitor: SessionMonitor {
    nonisolated static let discoveryWindow: TimeInterval = 8 * 60 * 60

    func start(into store: SessionStore) async {
        while !Task.isCancelled {
            if !store.isPaused {
                let now = Date.now
                let sessions = await Task.detached {
                    Self.discover(now: now, context: .local())
                }.value
                store.sync(tool: .grokBuild, sessions: sessions)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    nonisolated static func defaultRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".grok")
    }

    /// The root under the context's home, with a registered pid judged
    /// alive by the context's process table rather than by this Mac's.
    nonisolated static func discover(now: Date, context: DiscoveryContext) -> [AgentSession] {
        discover(
            root: defaultRoot(home: context.home), now: now,
            isLive: {
                context.processes.isAgent($0, names: ProcessIdentity.grokNames, recordedAt: $1)
            },
            isNamed: { context.processes.isNamedAgent($0, names: ProcessIdentity.grokNames) })
    }

    /// The session ids that are subagents of another session in the same
    /// directory, taken from each session's own `subagents/<id>/` listing.
    ///
    /// Read from the parent's declaration rather than guessed from the
    /// child's shape. A subagent directory is missing `terminal/` and
    /// `subagents/`, so absence of those looks like a usable heuristic, but
    /// it also describes a top-level session that has not spawned anything
    /// or is not attached to a terminal, and hiding one of those would lose
    /// a real row silently.
    nonisolated static func subagentIDs(in sessionDirs: [URL]) -> Set<String> {
        let fm = FileManager.default
        var ids: Set<String> = []
        for dir in sessionDirs {
            let listing = (try? fm.contentsOfDirectory(
                at: dir.appendingPathComponent("subagents"),
                includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in listing where isDirectory(child) {
                ids.insert(child.lastPathComponent)
            }
        }
        return ids
    }

    /// `isLive` gets an entry's pid and its opened_at, and by default holds
    /// the pid to being the Grok process that opened the session
    /// (ProcessIdentity): an entry outlives a crashed process, and kill(pid,
    /// 0) passed whatever got the number next, reviving the dead session's
    /// prompt with someone else's terminal behind it.
    ///
    /// `isNamed` gets a pid whose entry has no opened_at that reads, and
    /// says whether it is at least a Grok process of this user. Such an
    /// entry keeps its row alive and reports no pid (activeSessions).
    nonisolated static func discover(
        root: URL, now: Date, isLive: (Int, Date?) -> Bool = defaultIsLive,
        isNamed: (Int) -> Bool = defaultIsNamed
    ) -> [AgentSession] {
        let fm = FileManager.default
        let active = activeSessions(root: root, isLive: isLive, isNamed: isNamed)

        let sessionsRoot = root.appendingPathComponent("sessions")
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        var sessions: [AgentSession] = []
        for cwdDir in cwdDirs {
            guard isDirectory(cwdDir) else { continue }
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let subagents = subagentIDs(in: sessionDirs)
            for sessionDir in sessionDirs {
                guard isDirectory(sessionDir),
                      // A subagent gets a full session directory beside its
                      // parent's, so promoting every directory turned one
                      // Grok run into a row per subagent, all sharing the
                      // project's name and flipping between Active and
                      // Recent as they started and finished.
                      !subagents.contains(sessionDir.lastPathComponent),
                      let session = parseSession(
                        dir: sessionDir, activeIds: active.ids, pids: active.pids, now: now)
                else { continue }
                sessions.append(session)
            }
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Returns the tool name awaiting permission if the session's trailing
    /// phase is permission_prompt, nil once the prompt has been answered
    /// (a later phase_changed supersedes it).
    nonisolated static func pendingPermissionTool(dir: URL) -> String? {
        pendingPermission(dir: dir)?.tool
    }

    /// The tool awaiting permission and, where events.jsonl records one,
    /// the id of the call it is about.
    nonisolated static func pendingPermission(dir: URL) -> (tool: String, callID: String?)? {
        guard let tail = ClaudeCodeMonitor.tail(of: dir.appendingPathComponent("events.jsonl"))
        else { return nil }
        var requested: (tool: String?, callID: String?)?
        for raw in tail.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let line = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = line["type"] as? String
            else { continue }
            if type == "permission_requested", requested == nil {
                let callID = ["tool_call_id", "toolCallId", "call_id"]
                    .lazy.compactMap { line[$0] as? String }.first
                requested = (line["tool_name"] as? String, callID)
            }
            if type == "phase_changed" {
                guard (line["phase"] as? String) == "permission_prompt" else { return nil }
                return (requested?.tool ?? "tool", requested?.callID)
            }
        }
        return nil
    }

    /// The request the session's pending permission prompt is about, read
    /// now, or nil when the session is not at one.
    nonisolated static func pendingPrompt(dir: URL) -> ApprovalPrompt? {
        guard let pending = pendingPermission(dir: dir) else { return nil }
        guard let updates = promptUpdates(at: dir.appendingPathComponent("updates.jsonl")) else {
            return .unreadable(
                "Grok has not recorded what this \(pending.tool) call would do. Review it in the terminal.")
        }
        return GrokUpdatesParser.pendingToolPrompt(
            tail: updates.text, tool: pending.tool, callID: pending.callID,
            fromStart: updates.fromStart)
    }

    /// updates.jsonl for finding a gated call: the whole file up to the
    /// tail ceiling, else its last ceiling's worth, and whether the text
    /// runs from the file's real start. The status tail's 64 KB is not
    /// enough here: one large call record pushes everything before it out
    /// of the window, and the call that is waiting can be among them.
    ///
    /// A remote mirror holds a file at its true size with zeros wherever
    /// the helper shipped nothing, so reading from offset 0 there is not
    /// reading from the start. JSON never holds a raw NUL, which is how a
    /// hole is told from the file.
    nonisolated static func promptUpdates(at file: URL) -> (text: String, fromStart: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        if size <= UInt64(ClaudeCodeMonitor.maxTailBytes) {
            guard (try? handle.seek(toOffset: 0)) != nil,
                  let data = try? handle.read(upToCount: Int(size)) ?? Data()
            else { return nil }
            return (String(decoding: data, as: UTF8.self), !data.contains(0))
        }
        guard let text = ClaudeCodeMonitor.tail(of: file, startingAt: ClaudeCodeMonitor.maxTailBytes)
        else { return nil }
        return (text, false)
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// active_sessions.json's entries may be bare id strings or objects with
    /// an id under one of a few likely keys. Two liveness corrections
    /// observed in the wild: entries can outlive a crashed process (dead
    /// pid), and the TUI can switch sessions within one process, leaving
    /// the abandoned session still registered under the same pid. Only the
    /// newest opened_at per pid is genuinely attached.
    ///
    /// `isLive` is this Mac's identity check by default, and the context's
    /// process table when discovery reads a remote host.
    nonisolated static func activeSessionIDs(
        root: URL, isLive: (Int, Date?) -> Bool = defaultIsLive,
        isNamed: (Int) -> Bool = defaultIsNamed
    ) -> Set<String> {
        activeSessions(root: root, isLive: isLive, isNamed: isNamed).ids
    }

    nonisolated static func defaultIsLive(_ pid: Int, _ openedAt: Date?) -> Bool {
        ProcessIdentity.isProcess(pid, names: ProcessIdentity.grokNames, recordedAt: openedAt)
    }

    nonisolated static func defaultIsNamed(_ pid: Int) -> Bool {
        ProcessIdentity.isNamedProcess(pid, names: ProcessIdentity.grokNames)
    }

    /// An entry's opened_at, when it names an instant. The format has not
    /// been sampled from a live Grok 1.x, so any unambiguous spelling is
    /// read: ISO 8601 with a zone (a space for the T as well), or seconds
    /// or milliseconds since 1970. A time with no zone is not an instant,
    /// and reading it in the wrong zone would move the bound ProcessIdentity
    /// holds a pid to by hours, so it stays unread. So does an instant
    /// outside PlausibleDate's range: a far-future one would let any
    /// process's start time pass that bound.
    nonisolated static func openedAt(_ entry: [String: Any]) -> Date? {
        PlausibleDate.check(spelledOpenedAt(entry))
    }

    private nonisolated static func spelledOpenedAt(_ entry: [String: Any]) -> Date? {
        let value = entry["opened_at"]
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite, raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw >= 100_000_000_000 ? raw / 1000 : raw)
        }
        guard var text = value as? String else { return nil }
        if let parsed = ClaudeSessionParser.date(text) { return parsed }
        let scalars = Array(text.unicodeScalars)
        if scalars.count > 10, scalars[10] == " " {
            text = String(String.UnicodeScalarView(scalars[..<10])) + "T"
                + String(String.UnicodeScalarView(scalars[11...]))
            return ClaudeSessionParser.date(text)
        }
        return nil
    }

    /// The active ids as above, plus the pid each one's entry names where
    /// it names one. Bare id strings and entries without a pid are active
    /// with no pid to report.
    ///
    /// An entry whose opened_at does not read cannot be held to a start
    /// time. If its pid is at least a Grok process of this user (`isNamed`)
    /// its id is active, so a real session is not marked dead over a guess
    /// about a field, but it reports no pid: nothing proves that pid is
    /// THIS session's rather than a newer Grok's that got the number, and
    /// the pid is what terminals and signals are aimed by. Only a pid with
    /// exactly one such entry and no entry with a time counts, since with
    /// no times there is no telling which of two sessions is attached.
    private nonisolated static func activeSessions(
        root: URL, isLive: (Int, Date?) -> Bool, isNamed: (Int) -> Bool
    ) -> (ids: Set<String>, pids: [String: Int]) {
        let path = root.appendingPathComponent("active_sessions.json")
        guard let data = BoundedRead.data(of: path),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return ([], [:]) }
        let idKeys = ["id", "session_id", "sessionId", "sessionID"]

        var ids = Set<String>()
        var newestPerPid: [Int: (id: String, openedAt: Date)] = [:]
        var unprovenPerPid: [Int: [String]] = [:]
        var claimedPids = Set<Int>()
        for element in array {
            if let string = element as? String {
                ids.insert(string)
                continue
            }
            guard let entry = element as? [String: Any],
                  let id = idKeys.compactMap({ entry[$0] as? String }).first
            else { continue }
            guard let pid = entry["pid"] as? Int else {
                ids.insert(id)
                continue
            }
            let recorded = Self.openedAt(entry)
            if recorded != nil { claimedPids.insert(pid) }
            guard isLive(pid, recorded) else {
                if recorded == nil, isNamed(pid) { unprovenPerPid[pid, default: []].append(id) }
                continue
            }
            let openedAt = recorded ?? .distantPast
            if let current = newestPerPid[pid], current.openedAt >= openedAt { continue }
            newestPerPid[pid] = (id, openedAt)
        }
        ids.formUnion(newestPerPid.values.map(\.id))
        for (pid, unproven) in unprovenPerPid
        where unproven.count == 1 && newestPerPid[pid] == nil && !claimedPids.contains(pid) {
            ids.insert(unproven[0])
        }
        var pids: [String: Int] = [:]
        for (pid, entry) in newestPerPid { pids[entry.id] = pid }
        return (ids, pids)
    }

    private nonisolated static func parseSession(
        dir: URL, activeIds: Set<String>, pids: [String: Int], now: Date
    ) -> AgentSession? {
        let summaryPath = dir.appendingPathComponent("summary.json")
        guard let data = BoundedRead.data(of: summaryPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let info = json["info"] as? [String: Any]
        let infoId = info?["id"] as? String
        let cwd = info?["cwd"] as? String

        guard let createdAt = (json["created_at"] as? String).flatMap(ClaudeSessionParser.date),
              let updatedAt = (json["updated_at"] as? String).flatMap(ClaudeSessionParser.date)
        else { return nil }

        let age = now.timeIntervalSince(updatedAt)
        guard age < discoveryWindow else { return nil }

        let isActive = infoId.map { activeIds.contains($0) } ?? false
        let status: SessionStatus
        if isActive {
            // events.jsonl records permission prompts explicitly
            // (phase_changed to permission_prompt + permission_requested);
            // otherwise the update stream carries the working state.
            if let prompt = pendingPrompt(dir: dir) {
                status = .waitingApproval(command: prompt)
            } else {
                status = ClaudeCodeMonitor.tail(of: dir.appendingPathComponent("updates.jsonl"))
                    .flatMap { GrokUpdatesParser.parse(tail: $0) }
                    ?? .working(activity: "Working…")
            }
        } else {
            // No process means nothing to wait for; exited sessions are
            // idle no matter how fresh their last activity is.
            status = .idle
        }

        let id = rowID(infoID: infoId, dir: dir)
        let projectPath = cwd.map { URL(fileURLWithPath: $0) }

        return AgentSession(
            id: id,
            tool: .grokBuild,
            projectName: projectPath?.lastPathComponent ?? dir.lastPathComponent,
            projectPath: projectPath,
            status: status,
            startedAt: createdAt,
            lastActivityAt: updatedAt,
            pid: isActive ? infoId.flatMap { pids[$0] }.flatMap { pid_t(processID: $0) } : nil,
            processAlive: isActive
        )
    }

    /// The row id of a session directory: the id its summary names, else
    /// one derived from the directory's name.
    nonisolated static func rowID(infoID: String?, dir: URL) -> UUID {
        infoID.flatMap { UUID(uuidString: $0) } ?? StableID.uuid(for: dir.lastPathComponent)
    }

    /// The one session directory under `root` (a ~/.grok) whose row id,
    /// passed through `rowID` (a remote row is rekeyed per host and home),
    /// is `id`. Nil when none is, or more than one is, since two
    /// directories claiming one row cannot say which prompt it showed.
    nonisolated static func sessionDir(
        id: UUID, root: URL, rowID mapped: (UUID) -> UUID = { $0 }
    ) -> URL? {
        let fm = FileManager.default
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: root.appendingPathComponent("sessions"), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [URL] = []
        for cwdDir in cwdDirs where isDirectory(cwdDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in sessionDirs where isDirectory(dir) {
                guard let data = BoundedRead.data(of: dir.appendingPathComponent("summary.json")),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }
                let infoID = (json["info"] as? [String: Any])?["id"] as? String
                if mapped(rowID(infoID: infoID, dir: dir)) == id { found.append(dir) }
            }
        }
        return found.count == 1 ? found[0] : nil
    }
}

/// Whether a Grok Approve or Deny may be pressed, judged on Grok's own
/// state read at click time.
///
/// The row is a poll behind the terminal: 5 s here, about 10 s through a
/// host's mirror, and a hook pin can be older still. In between, the call
/// it showed can be answered at the terminal and Grok can gate another,
/// and the press-time checks confirm only an option label and the marked
/// line, which read the same on every Grok gate. So the press goes ahead
/// only when the prompt Grok records as pending, read again now, is the
/// very request the row showed.
enum GrokAnswerCheck {
    nonisolated static func mayAnswer(shown: ApprovalPrompt, pending: ApprovalPrompt?) -> Bool {
        guard shown.offersApprove, let pending else { return false }
        return pending == shown
    }

    /// The pending prompt of the session behind a row on this Mac, read
    /// from its state now. Nil when it is not at a prompt or its
    /// directory cannot be found.
    nonisolated static func livePending(
        sessionID: UUID, root: URL = GrokBuildMonitor.defaultRoot()
    ) -> ApprovalPrompt? {
        guard let dir = GrokBuildMonitor.sessionDir(id: sessionID, root: root) else { return nil }
        return GrokBuildMonitor.pendingPrompt(dir: dir)
    }

    /// What a remote Grok answer is bound to: the pending prompt read from
    /// the host's mirror now, the host path of the session's events.jsonl,
    /// and that file's size as the mirror holds it. The helper presses only
    /// if nothing written to the file since that size records a prompt
    /// opening, closing or changing phase, so the check runs on the host in
    /// the same step as the press, not only here a round trip earlier.
    ///
    /// The size is read before the prompt. A snapshot landing in between
    /// can only make the prompt newer than the size, and the helper then
    /// checks more of the file, never less.
    nonisolated static func remoteBinding(
        sessionID: UUID, hostID: UUID, homes: [String], mirror: RemoteMirror
    ) -> (prompt: ApprovalPrompt?, events: RemoteEventsAnchor)? {
        var found: [(home: String, dir: URL)] = []
        for home in homes {
            guard let local = mirror.local(home),
                  let dir = GrokBuildMonitor.sessionDir(
                    id: sessionID, root: GrokBuildMonitor.defaultRoot(home: local),
                    rowID: { RemoteIdentity.sessionID(hostID: hostID, home: home, localID: $0) })
            else { continue }
            found.append((home, dir))
        }
        guard found.count == 1, let (home, dir) = found.first else { return nil }
        let events = dir.appendingPathComponent("events.jsonl")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: events.path))?[.size] as? Int
        else { return nil }
        // Built from the names, not from the mirror path, which the file
        // system may have spelled differently (/var against /private/var).
        let cwdName = dir.deletingLastPathComponent().lastPathComponent
        let path = (home.hasSuffix("/") ? String(home.dropLast()) : home)
            + "/.grok/sessions/\(cwdName)/\(dir.lastPathComponent)/events.jsonl"
        return (GrokBuildMonitor.pendingPrompt(dir: dir), RemoteEventsAnchor(path: path, size: size))
    }
}
