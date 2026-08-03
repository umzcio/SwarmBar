import Foundation

/// Focuses the terminal tab actually hosting a Claude Code session:
/// session id -> pid via the ~/.claude*/sessions process records,
/// pid -> tty via ps, tty -> tab by scripting iTerm2 or Terminal (only
/// when already running, so nothing gets launched). Falls back to opening
/// the project directory in a new Terminal window.
enum TerminalFocuser {
    nonisolated static func focus(sessionID: UUID, projectPath: URL?) {
        if let tty = tty(forSession: sessionID),
           focusRunningTerminal(device: "/dev/\(tty)") {
            return
        }
        if let path = projectPath?.path {
            _ = run("/usr/bin/open", ["-a", "Terminal", path])
        }
    }

    // MARK: - Session -> tty

    private nonisolated static func tty(forSession id: UUID) -> String? {
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
                let name = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let name, !name.isEmpty, name != "??" { return name }
            }
        }
        return nil
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
