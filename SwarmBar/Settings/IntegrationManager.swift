import Foundation
import Observation

/// Detects and toggles the per-tool integration pieces. Monitors work
/// with zero configuration; what installs here are the approval bridges:
/// Claude's hook entries, the Kimi-family [[hooks]] tables, and the
/// OpenCode plugin. Every touched config gets a one-time
/// .backup-swarmbar copy, and writes resolve symlinks first so shared
/// dotfiles (all Claude profiles symlink one settings.json) are edited
/// in place instead of being replaced by a regular file.
@MainActor
@Observable
final class IntegrationManager {
    enum InstallState: Equatable {
        case installed
        case notInstalled
        case toolMissing
        case noSetupNeeded
        case failed(String)

        var label: String {
            switch self {
            case .installed:     "Installed"
            case .notInstalled:  "Not installed"
            case .toolMissing:   "Not detected on this Mac"
            case .noSetupNeeded: "No setup needed"
            case .failed(let m): m
            }
        }
    }

    private(set) var states: [AgentTool: InstallState] = [:]

    /// Marks a bridge script that sends the SwarmBar-Token header. An
    /// installed copy in Application Support without this marker predates
    /// the token and would silently fail open, so it counts as not
    /// installed until the toggle overwrites it.
    static let bridgeMarker = "swarmbar-bridge-v2"

    private let fm = FileManager.default
    private var home: URL { fm.homeDirectoryForCurrentUser }

    private var appSupport: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwarmBar")
    }

    // MARK: - Detection

    func refresh() {
        states[.claudeCode] = detectClaude()
        states[.codex] = fm.fileExists(atPath: home.appendingPathComponent(".codex").path)
            ? .noSetupNeeded : .toolMissing
        states[.grokBuild] = fm.fileExists(atPath: home.appendingPathComponent(".grok").path)
            ? .noSetupNeeded : .toolMissing
        // Read only for now: the conversation database gives status without
        // any bridge, and approve/deny is not wired. See AntigravityMonitor.
        states[.antigravity] = fm.fileExists(
            atPath: home.appendingPathComponent(".gemini/antigravity-cli").path)
            ? .noSetupNeeded : .toolMissing
        states[.kimiCode] = detectTomlTool(configDir: ".kimi-code")
        states[.bearCode] = detectTomlTool(configDir: ".bearcode")
        states[.openCode] = detectOpenCode()
    }

    private func detectClaude() -> InstallState {
        let settings = home.appendingPathComponent(".claude/settings.json")
        guard fm.fileExists(atPath: home.appendingPathComponent(".claude").path) else {
            return .toolMissing
        }
        let text = (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
        guard ClaudeHookTransform.isInstalled(text) else { return .notInstalled }
        return scriptIsCurrent(named: "swarmbar-hook.sh") ? .installed : .notInstalled
    }

    private func detectTomlTool(configDir: String) -> InstallState {
        let dir = home.appendingPathComponent(configDir)
        guard fm.fileExists(atPath: dir.path) else { return .toolMissing }
        let text = (try? String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        guard TomlHooksTransform.isInstalled(text) else { return .notInstalled }
        return scriptIsCurrent(named: "swarmbar-kimi-hook.sh") ? .installed : .notInstalled
    }

    /// True unless the toggle previously copied an older script into
    /// Application Support that predates the token. A config referencing a
    /// hand-installed script that lives elsewhere (pointing straight at the
    /// repo's scripts/, already updated in place) has no copy here at all,
    /// so it is left alone.
    private func scriptIsCurrent(named name: String) -> Bool {
        let installed = appSupport.appendingPathComponent(name)
        guard fm.fileExists(atPath: installed.path) else { return true }
        let text = (try? String(contentsOf: installed, encoding: .utf8)) ?? ""
        return text.contains(Self.bridgeMarker)
    }

    private func detectOpenCode() -> InstallState {
        let configDir = home.appendingPathComponent(".config/opencode")
        let dataDir = home.appendingPathComponent(".local/share/opencode")
        guard fm.fileExists(atPath: configDir.path) || fm.fileExists(atPath: dataDir.path) else {
            return .toolMissing
        }
        guard let config = openCodeConfigURL() else { return .notInstalled }
        let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        return OpenCodeConfigTransform.isInstalled(text) ? .installed : .notInstalled
    }

    // MARK: - Toggling

    func setEnabled(_ tool: AgentTool, _ enabled: Bool) {
        do {
            switch tool {
            case .claudeCode:
                try toggleClaude(enabled)
            case .kimiCode:
                try toggleToml(configDir: ".kimi-code", enabled: enabled)
            case .bearCode:
                try toggleToml(configDir: ".bearcode", enabled: enabled)
            case .openCode:
                try toggleOpenCode(enabled)
            case .codex, .grokBuild, .antigravity:
                break
            }
            refresh()
        } catch {
            states[tool] = .failed(error.localizedDescription)
        }
    }

    private func toggleClaude(_ enabled: Bool) throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        let text = try readOrEmpty(settings, fallback: "{}\n")
        let updated: String
        if enabled {
            let script = try installScript(named: "swarmbar-hook.sh")
            updated = try ClaudeHookTransform.install(text, scriptPath: script.path)
        } else {
            updated = try ClaudeHookTransform.uninstall(text)
        }
        try writeBackedUp(updated, to: settings)
    }

    private func toggleToml(configDir: String, enabled: Bool) throws {
        let config = home.appendingPathComponent(configDir).appendingPathComponent("config.toml")
        let text = try readOrEmpty(config, fallback: "")
        let updated: String
        if enabled {
            let script = try installScript(named: "swarmbar-kimi-hook.sh")
            updated = TomlHooksTransform.install(text, scriptPath: script.path)
        } else {
            updated = TomlHooksTransform.uninstall(text)
        }
        try writeBackedUp(updated, to: config)
    }

    private func toggleOpenCode(_ enabled: Bool) throws {
        let pluginDir = home.appendingPathComponent(".config/opencode/plugins")
        let plugin = pluginDir.appendingPathComponent("swarmbar.js")
        let config = openCodeConfigURL()
            ?? home.appendingPathComponent(".config/opencode/opencode.json")
        let text = try readOrEmpty(config, fallback: "{}\n")
        if enabled {
            try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            let bundled = try bundledResource(named: "swarmbar-opencode.js")
            try bundled.write(to: plugin, atomically: true, encoding: .utf8)
            let updated = try OpenCodeConfigTransform.install(
                text, pluginSpec: "file://\(plugin.path)")
            try writeBackedUp(updated, to: config)
        } else {
            let updated = try OpenCodeConfigTransform.uninstall(text)
            try writeBackedUp(updated, to: config)
            try? fm.removeItem(at: plugin)
        }
    }

    private func openCodeConfigURL() -> URL? {
        let dir = home.appendingPathComponent(".config/opencode")
        for name in ["opencode.jsonc", "opencode.json"] {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - File plumbing

    /// Copies a bundled script into Application Support and returns its
    /// installed location, so configs never point into the app bundle
    /// (which moves on every update).
    private func installScript(named name: String) throws -> URL {
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let destination = appSupport.appendingPathComponent(name)
        let contents = try bundledResource(named: name)
        try contents.write(to: destination, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    private func bundledResource(named name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw IntegrationTransformError.unparseable("\(name) missing from the app bundle")
        }
        return text
    }

    private func readOrEmpty(_ url: URL, fallback: String) throws -> String {
        guard fm.fileExists(atPath: url.resolvingSymlinksInPath().path) else { return fallback }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// One-time backup beside the original, then write through any
    /// symlink so shared dotfiles stay shared.
    private func writeBackedUp(_ text: String, to url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        let backup = resolved.appendingPathExtension("backup-swarmbar")
        if fm.fileExists(atPath: resolved.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: resolved, to: backup)
        }
        try Self.writePreservingLinks(text, to: resolved)
    }

    /// Writes `text` to `url` so that every hardlink to it sees the new
    /// content.
    ///
    /// An atomic write stages a temp file and renames it over the
    /// destination, which swaps in a fresh inode: any other hardlink keeps
    /// pointing at the old one and silently goes stale. Config files shared
    /// between agent profiles by hardlink would then be updated in one place
    /// only, so a toggle would look applied while most profiles kept the old
    /// hooks.
    ///
    /// Symlinks are not affected either way (the caller has already resolved
    /// them), so the common single-link case keeps the atomic write and its
    /// crash safety. Only a genuinely hardlinked file takes the in place
    /// path, where preserving the inode is worth losing atomicity.
    nonisolated static func writePreservingLinks(_ text: String, to url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let links = (attributes?[.referenceCount] as? Int) ?? 1
        guard links > 1 else {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
    }
}
