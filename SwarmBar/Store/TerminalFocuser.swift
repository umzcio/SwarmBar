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
        // `open -a Terminal` on a regular file hands the file to Terminal to
        // run, so only ever pass a real directory. Project paths can come
        // from a hook payload, which is not trusted input.
        guard let path = projectPath?.path, isDirectory(path) else { return }
        _ = run("/usr/bin/open", ["-a", "Terminal", path])
    }

    nonisolated static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
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
        return runScript(keyScript(tty: tty, keys: keys)) == "SENT"
    }

    /// The iTerm2 script that writes `keys` to the session on `tty`. Pure, so
    /// the emitted script can be asserted without driving a terminal.
    nonisolated static func keyScript(tty: String, keys: [String]) -> String {
        let writes = keys.map { key in
            switch key {
            case "\n":   "tell s to write text \"\""
            case "UP":   "tell s to write text ((character id 27) & \"[A\") newline NO"
            case "DOWN": "tell s to write text ((character id 27) & \"[B\") newline NO"
            case "ESC":  "tell s to write text (character id 27) newline NO"
            // Escaped so a key carrying a quote or backslash cannot end the
            // literal early and change the script. Digits and the fixed
            // tokens above are unaffected, so existing behavior is identical.
            default:     "tell s to write text \"\(AppleScriptLiteral.escape(key))\" newline NO"
            }
        }.joined(separator: "\n          delay 0.08\n          ")
        return """
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
    }

    /// The visible screen text of the session's terminal (iTerm2 only).
    /// Used to read a TUI selector's actual options before answering, so
    /// keystrokes target a verified choice instead of a guessed position.
    nonisolated static func screenText(sessionID: UUID, projectPath: URL? = nil) -> String? {
        guard let tty = tty(forSession: sessionID, projectPath: projectPath)
        else { return nil }
        return screenText(tty: tty)
    }

    /// The same read for a caller that already knows the pid, which is the
    /// monitors: Antigravity's presence lock hands one over, and the
    /// terminal is the only place that says whether its unsettled step is
    /// waiting on the user or merely running.
    nonisolated static func screenText(pid: Int) -> String? {
        let name = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, name != "??" else { return nil }
        return screenText(tty: name)
    }

    nonisolated static func screenText(tty: String) -> String? {
        guard isRunning("iTerm2") else { return nil }
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

    enum AnswerOutcome: Equatable {
        /// The digit was written to a selector that still showed the expected
        /// label at that number.
        case sent
        /// The screen changed between reading and writing, so nothing was sent.
        case promptChanged
        /// No live tty, or iTerm2 is not running.
        case noTerminal
    }

    // MARK: - Inline reply

    enum ReplyOutcome: Equatable {
        /// The paste was seen in the composer and Enter was sent.
        case sent
        /// The paste did not appear on screen, so Enter was NOT sent. The
        /// text may be partially there; the user finishes at the terminal.
        case pasteNotVisible
        /// No live tty, or iTerm2 is not running.
        case noTerminal
    }

    /// The iTerm2 script that pastes `text` into the session on `tty`. Pure,
    /// so the emitted script can be asserted without driving a terminal.
    ///
    /// Uses bracketed paste (ESC[200~ ... ESC[201~) rather than typing: a TUI
    /// that supports it takes the whole payload as literal content, so
    /// embedded newlines land as line breaks instead of submitting the prompt
    /// at the first one. This is a terminal-level protocol, so it is the same
    /// mechanism for every tool rather than six per-app newline conventions.
    ///
    /// Deliberately contains NO submit. Pasting and pressing Enter are
    /// separate steps so the paste can be verified on screen in between.
    nonisolated static func pasteScript(tty: String, text: String) -> String {
        let payload = AppleScriptLiteral.expression(text)
        return """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "/dev/\(AppleScriptLiteral.escape(tty))" then
                  set payload to \(payload)
                  tell s to write text ((character id 27) & "[200~" & payload & (character id 27) & "[201~") newline NO
                  return "PASTED"
                end if
              end repeat
            end repeat
          end repeat
          return "MISS"
        end tell
        """
    }

    /// Pastes `text` into the session's composer, confirms it actually landed
    /// by reading the screen back, and only then submits. Never presses Enter
    /// on text it could not see: a half-delivered prompt left sitting in the
    /// composer is recoverable, a half-delivered prompt that was submitted is
    /// not.
    nonisolated static func sendReply(
        sessionID: UUID, projectPath: URL?, text: String
    ) -> ReplyOutcome {
        guard let tty = tty(forSession: sessionID, projectPath: projectPath),
              isRunning("iTerm2"),
              runScript(pasteScript(tty: tty, text: text)) == "PASTED"
        else { return .noTerminal }

        // Confirm on screen before submitting. A distinctive slice of the
        // reply is enough, and the last line is what sits nearest the cursor.
        guard let probe = verificationProbe(for: text),
              let screen = screenText(sessionID: sessionID, projectPath: projectPath),
              screen.contains(probe)
        else { return .pasteNotVisible }

        return runScript(keyScript(tty: tty, keys: ["\n"])) == "SENT"
            ? .sent
            : .pasteNotVisible
    }

    /// A slice of the reply to look for on screen. The composer may wrap or
    /// re-indent long text, so match a short run from the final line rather
    /// than the whole payload.
    nonisolated static func verificationProbe(for text: String) -> String? {
        let lastLine = text
            .components(separatedBy: "\n")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let trimmed = lastLine?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty
        else { return nil }
        return String(trimmed.suffix(24))
    }

    /// Presses `number` only if line `number` on screen still contains
    /// `expectedLabel`. Read and write happen in one script so the prompt
    /// cannot advance in between: two round trips left a window in which a
    /// digit could land in a different selector.
    nonisolated static func answerNumbered(
        sessionID: UUID, projectPath: URL?, number: Int, expectedLabel: String
    ) -> AnswerOutcome {
        guard let tty = tty(forSession: sessionID, projectPath: projectPath),
              isRunning("iTerm2") else { return .noTerminal }
        let needle = expectedLabel.replacingOccurrences(of: "\"", with: "")
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "/dev/\(tty)" then
                  set screenText to (text of s)
                  if screenText contains "\(needle)" then
                    tell s to write text "\(number)" newline NO
                    return "SENT"
                  else
                    return "CHANGED"
                  end if
                end if
              end repeat
            end repeat
          end repeat
          return "MISS"
        end tell
        """
        switch runScript(script) {
        case "SENT":    return .sent
        case "CHANGED": return .promptChanged
        default:        return .noTerminal
        }
    }

    /// Moves the selector's cursor to a labeled option and submits.
    ///
    /// For tools whose prompts take arrow keys rather than digits. Like
    /// `answerNumbered`, the read and the press are one script, so the
    /// prompt cannot advance between confirming what is on screen and
    /// acting on it: two round trips leave a window in which the keys land
    /// in a selector nobody read.
    ///
    /// The caller computes the presses from a screen it has already read,
    /// and this re-confirms that same screen before sending. Confirming
    /// the label alone would not be enough, since the cursor may have
    /// moved while the label stayed put, so the marked line is checked
    /// too.
    nonisolated static func answerByNavigation(
        sessionID: UUID,
        projectPath: URL?,
        key: String,
        presses: Int,
        expectedCursorLine: String,
        expectedLabel: String
    ) -> AnswerOutcome {
        guard presses >= 0, key == "UP" || key == "DOWN",
              let tty = tty(forSession: sessionID, projectPath: projectPath),
              isRunning("iTerm2")
        else { return .noTerminal }

        let arrow = key == "UP" ? "[A" : "[B"
        let moves = (0..<presses)
            .map { _ in "tell s to write text ((character id 27) & \"\(arrow)\") newline NO" }
            .joined(separator: "\n                    delay 0.08\n                    ")
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "/dev/\(tty)" then
                  set screenText to (text of s)
                  if screenText contains "\(AppleScriptLiteral.escape(expectedLabel))" ¬
                    and screenText contains "\(AppleScriptLiteral.escape(expectedCursorLine))" then
                    \(moves.isEmpty ? "" : moves + "\n                    delay 0.08")
                    tell s to write text ""
                    return "SENT"
                  else
                    return "CHANGED"
                  end if
                end if
              end repeat
            end repeat
          end repeat
          return "MISS"
        end tell
        """
        switch runScript(script) {
        case "SENT":    return .sent
        case "CHANGED": return .promptChanged
        default:        return .noTerminal
        }
    }

    // MARK: - Session -> tty

    private nonisolated static func tty(forSession id: UUID, projectPath: URL? = nil) -> String? {
        let pid = claudePid(forSession: id)
            ?? grokPid(forSession: id)
            ?? codexPid(forSession: id)
            ?? antigravityPid(forSession: id)
            ?? kimiPid(projectPath: projectPath)
        if let pid {
            let name = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty, name != "??" { return name }
        }
        return nil
    }

    /// Antigravity publishes the cleanest session-to-pid map of any tool
    /// here: it holds presence/<conversation-id>.lock open for the life of
    /// the session, so the kernel already knows which pid is which
    /// conversation. No directory matching, and two sessions in one repo
    /// stay distinguishable.
    private nonisolated static func antigravityPid(forSession id: UUID) -> Int? {
        AntigravityReader.liveConversations()
            .first { StableID.uuid(for: $0.key) == id }?
            .value
    }

    /// Kimi (and its BearCode fork) have no session-to-pid registry, but
    /// their processes keep the session's workDir as cwd, so match on
    /// that (newest process wins when two sessions share a directory).
    private nonisolated static func kimiPid(projectPath: URL?) -> Int? {
        guard let path = projectPath?.path else { return nil }
        return ProcessLiveness.pid(processName: "kimi", cwd: path)
            // BearCode from 0.34.0 renames itself via process.title, so the
            // command-line match alone stopped resolving a pid here. With no
            // pid there is no tty, the selector cannot be read, and Approve
            // degraded to opening an empty terminal window.
            ?? ProcessLiveness.pid(
                processName: KimiMonitor.BearCode.processName,
                orCommandPattern: KimiMonitor.BearCode.commandPattern,
                cwd: path)
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
            guard let output = run("/usr/sbin/lsof", ["-n", "-P", "-F", "p", file.path])
            else { continue }
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
    ///
    /// `-n` and `-P` are load bearing for speed, not for output. Without
    /// them lsof reverse-resolves every network socket on the machine, and
    /// this call is on a five second poll: measured on a real machine it
    /// took 25.3 seconds and returned 46,181 lines, so the Codex monitor's
    /// true cadence was about thirty seconds and a full descriptor scan ran
    /// forever. With them it takes 0.16 seconds. The flags only affect how
    /// NETWORK addresses are printed, never file paths, which is all this
    /// reads: against a fixed set of pids both spellings produce identical
    /// output.
    nonisolated static func codexPidsBySessionSuffix() -> [String: Int] {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions").path
        guard let output = run("/usr/sbin/lsof", ["-n", "-P", "-F", "pn"]) else { return [:] }
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
