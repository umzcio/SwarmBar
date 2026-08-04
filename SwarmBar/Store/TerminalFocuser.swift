import Foundation

/// Focuses the terminal tab actually hosting a Claude Code session:
/// session id -> pid via the ~/.claude*/sessions process records,
/// pid -> tty via ps, tty -> tab by scripting iTerm2 or Terminal (only
/// when already running, so nothing gets launched). Falls back to opening
/// the project directory in a new Terminal window.
enum TerminalFocuser {
    nonisolated static func focus(sessionID: UUID, projectPath: URL?) {
        if let tty = tty(forSession: sessionID, projectPath: projectPath),
           focusRunningTerminal(device: "/dev/\(tty)") {
            return
        }
        if let path = projectPath?.path {
            _ = run("/usr/bin/open", ["-a", "Terminal", path])
        }
    }

    /// Sends keystrokes to the session's tty via iTerm2 (the only terminal
    /// here with a per-session write-text verb). "\n" sends a bare newline,
    /// "UP"/"DOWN" send arrow escape sequences, anything else is written
    /// without a newline. Used to answer Grok's TUI permission selector
    /// remotely. Returns false when the session has no live tty or iTerm2
    /// isn't running.
    nonisolated static func sendKeys(sessionID: UUID, projectPath: URL? = nil, keys: [String]) -> Bool {
        guard let tty = tty(forSession: sessionID, projectPath: projectPath),
              isRunning("iTerm2") else { return false }
        let writes = keys.map { key in
            switch key {
            case "\n":   "tell s to write text \"\""
            case "UP":   "tell s to write text ((character id 27) & \"[A\") newline NO"
            case "DOWN": "tell s to write text ((character id 27) & \"[B\") newline NO"
            case "ESC":  "tell s to write text (character id 27) newline NO"
            default:     "tell s to write text \"\(key)\" newline NO"
            }
        }.joined(separator: "\n          delay 0.08\n          ")
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "/dev/\(tty)" then
                  \(writes)
                  return "SENT"
                end if
              end repeat
            end repeat
          end repeat
          return "MISS"
        end tell
        """
        return runScript(script) == "SENT"
    }

    /// The visible screen text of the session's terminal (iTerm2 only).
    /// Used to read a TUI selector's actual options before answering, so
    /// keystrokes target a verified choice instead of a guessed position.
    nonisolated static func screenText(sessionID: UUID, projectPath: URL? = nil) -> String? {
        guard let tty = tty(forSession: sessionID, projectPath: projectPath),
              isRunning("iTerm2") else { return nil }
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "/dev/\(tty)" then return (text of s)
              end repeat
            end repeat
          end repeat
          return ""
        end tell
        """
        let text = run("/usr/bin/osascript", ["-e", script])
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: - Session -> tty

    private nonisolated static func tty(forSession id: UUID, projectPath: URL? = nil) -> String? {
        let pid = claudePid(forSession: id)
            ?? grokPid(forSession: id)
            ?? codexPid(forSession: id)
            ?? kimiPid(projectPath: projectPath)
        if let pid {
            let name = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty, name != "??" { return name }
        }
        return nil
    }

    /// Kimi (and its BearCode fork) have no session-to-pid registry, but
    /// their processes keep the session's workDir as cwd, so match on
    /// that (newest process wins when two sessions share a directory).
    private nonisolated static func kimiPid(projectPath: URL?) -> Int? {
        guard let path = projectPath?.path else { return nil }
        return ProcessLiveness.pid(processName: "kimi", cwd: path)
            ?? ProcessLiveness.pid(
                commandPattern: KimiMonitor.BearCode.commandPattern, cwd: path)
    }

    private nonisolated static func grokPid(forSession id: UUID) -> Int? {
        let active = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/active_sessions.json")
        guard let data = try? Data(contentsOf: active),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        for entry in entries {
            guard let sessionId = entry["session_id"] as? String,
                  sessionId.lowercased() == id.uuidString.lowercased(),
                  let pid = entry["pid"] as? Int,
                  kill(pid_t(pid), 0) == 0
            else { continue }
            return pid
        }
        return nil
    }

    /// Codex has no session-to-pid registry, but the codex process keeps
    /// its rollout file (whose name ends in the session id) open for
    /// appending, so lsof on that file names the owning process.
    nonisolated static func codexPid(forSession id: UUID) -> Int? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let suffix = "\(id.uuidString.lowercased()).jsonl"
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in enumerator
        where file.lastPathComponent.lowercased().hasSuffix(suffix) {
            guard let output = run("/usr/sbin/lsof", ["-F", "p", file.path]) else { continue }
            for line in output.split(separator: "\n") where line.hasPrefix("p") {
                if let pid = Int(line.dropFirst()), kill(pid_t(pid), 0) == 0 { return pid }
            }
        }
        return nil
    }

    nonisolated static func claudePid(forSession id: UUID) -> Int? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let entries = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(".claude") {
            let sessionsDir = entry.appendingPathComponent("sessions")
            let records = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
            for record in records where record.pathExtension == "json" {
                guard let data = try? Data(contentsOf: record),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let sessionId = json["sessionId"] as? String,
                      sessionId.lowercased() == id.uuidString.lowercased(),
                      let pid = json["pid"] as? Int,
                      kill(pid_t(pid), 0) == 0
                else { continue }
                return pid
            }
        }
        return nil
    }

    /// sessionId to pid for every live Claude session record, read once.
    /// Discovery calls this instead of `claudePid(forSession:)` per
    /// session: same walk and re-parse cost, paid once per poll instead of
    /// once per session per poll. `claudePid(forSession:)` stays for the
    /// answer path (TerminalFocuser.tty), where a single lookup is fine.
    nonisolated static func claudePidsBySession() -> [String: Int] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var result: [String: Int] = [:]
        let entries = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(".claude") {
            let sessionsDir = entry.appendingPathComponent("sessions")
            let records = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
            for record in records where record.pathExtension == "json" {
                guard let data = try? Data(contentsOf: record),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let sessionId = (json["sessionId"] as? String)?.lowercased(),
                      let pid = json["pid"] as? Int,
                      kill(pid_t(pid), 0) == 0
                else { continue }
                result[sessionId] = pid
            }
        }
        return result
    }

    /// pid for every codex rollout file currently held open, in one sweep.
    /// The per session version (`codexPid(forSession:)`) walks the whole
    /// sessions tree and spawns lsof each time; discovery called it once
    /// per session per poll.
    ///
    /// This does not filter lsof by process name (`-c codex`): there was
    /// no live Codex process available to confirm that filter matches the
    /// real process name, so this takes the slower but verifiably correct
    /// path the plan describes as the fallback: an unfiltered system-wide
    /// lsof, with results narrowed by the `~/.codex/sessions` path prefix
    /// instead of by process name.
    nonisolated static func codexPidsBySessionSuffix() -> [String: Int] {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions").path
        guard let output = run("/usr/sbin/lsof", ["-F", "pn"]) else { return [:] }
        var result: [String: Int] = [:]
        var currentPid: Int?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPid = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPid {
                let path = String(line.dropFirst())
                guard path.hasPrefix(sessionsRoot),
                      path.hasSuffix(".jsonl"),
                      let name = path.split(separator: "/").last,
                      name.hasPrefix("rollout-"), name.count >= 42
                else { continue }
                // <36-char-uuid>.jsonl is 42 characters; this must match
                // the "\(id.uuidString.lowercased()).jsonl" lookup key
                // exactly, or every lookup misses and every Codex session
                // reads as dead.
                let suffix = String(name.suffix(42))
                result[suffix.lowercased()] = pid
            }
        }
        return result
    }

    // MARK: - tty -> terminal tab

    private nonisolated static func focusRunningTerminal(device: String) -> Bool {
        if isRunning("iTerm2"), runScript(iTermScript(device: device)) == "FOCUSED" {
            return true
        }
        if isRunning("Terminal"), runScript(terminalScript(device: device)) == "FOCUSED" {
            return true
        }
        return false
    }

    private nonisolated static func iTermScript(device: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(device)" then
                  select s
                  select t
                  select w
                  activate
                  return "FOCUSED"
                end if
              end repeat
            end repeat
          end repeat
          return "MISS"
        end tell
        """
    }

    private nonisolated static func terminalScript(device: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(device)" then
                set selected of t to true
                set index of w to 1
                activate
                return "FOCUSED"
              end if
            end repeat
          end repeat
          return "MISS"
        end tell
        """
    }

    // MARK: - Helpers

    private nonisolated static func isRunning(_ processName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-xq", processName]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private nonisolated static func runScript(_ script: String) -> String? {
        run("/usr/bin/osascript", ["-e", script])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
