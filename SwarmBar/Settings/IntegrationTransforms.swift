import Foundation

/// Pure text transforms behind the settings toggles: each takes a config
/// file's contents and returns the new contents, so the merge/removal
/// logic is testable without touching the filesystem. All of them are
/// idempotent (install replaces any prior SwarmBar entries) and
/// conservative (uninstall touches only entries that mention swarmbar).
enum IntegrationTransformError: Error, LocalizedError {
    case unparseable(String)

    var errorDescription: String? {
        switch self {
        case .unparseable(let detail): detail
        }
    }
}

/// ~/.claude/settings.json: hook entries under hooks.<Event> arrays.
enum ClaudeHookTransform {
    static let events: [(name: String, timeout: Int)] = [
        ("PermissionRequest", 360),
        ("Stop", 5),
        ("UserPromptSubmit", 5),
        ("SessionEnd", 2),
    ]

    static func isInstalled(_ text: String) -> Bool {
        text.contains("swarmbar-hook.sh")
    }

    static func install(_ text: String, scriptPath: String) throws -> String {
        var root = try parse(text)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !mentionsSwarmBar($0) }
            entries.append([
                "hooks": [[
                    "type": "command",
                    "command": "bash \(scriptPath) \(event)",
                    "timeout": timeout,
                ]],
            ])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    static func uninstall(_ text: String) throws -> String {
        var root = try parse(text)
        guard var hooks = root["hooks"] as? [String: Any] else { return text }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !mentionsSwarmBar($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    private static func mentionsSwarmBar(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains("swarmbar") == true }
    }

    private static func parse(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw IntegrationTransformError.unparseable("settings.json is not valid JSON")
        }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Kimi-family config.toml: [[hooks]] tables, appended inside marker
/// comments so removal is exact. Uninstall also sweeps unmarked [[hooks]]
/// tables that mention swarmbar (migration from hand-installed entries).
enum TomlHooksTransform {
    static let beginMarker = "# >>> SwarmBar hooks >>>"
    static let endMarker = "# <<< SwarmBar hooks <<<"

    static let events: [(name: String, timeout: Int?)] = [
        ("PermissionRequest", nil),
        ("PermissionResult", nil),
        ("PreToolUse", 10),
        ("Stop", 10),
        ("SessionEnd", nil),
    ]

    static func isInstalled(_ text: String) -> Bool {
        text.contains("swarmbar-kimi-hook.sh") || text.contains(beginMarker)
    }

    static func install(_ text: String, scriptPath: String) -> String {
        var block = [beginMarker]
        for (event, timeout) in events {
            block.append("")
            block.append("[[hooks]]")
            block.append("event = \"\(event)\"")
            block.append("command = \"\(scriptPath) \(event)\"")
            if let timeout { block.append("timeout = \(timeout)") }
        }
        block.append(endMarker)
        let cleaned = uninstall(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned + "\n\n" + block.joined(separator: "\n") + "\n"
    }

    static func uninstall(_ text: String) -> String {
        var lines: [String] = []
        var inMarkedBlock = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker { inMarkedBlock = true; continue }
            if trimmed == endMarker { inMarkedBlock = false; continue }
            if !inMarkedBlock { lines.append(line) }
        }
        // Sweep unmarked [[hooks]] tables that mention swarmbar.
        var kept: [String] = []
        var block: [String] = []
        var inHooksBlock = false
        func flush() {
            if inHooksBlock, block.contains(where: { $0.contains("swarmbar") }) {
                // dropped
            } else {
                kept.append(contentsOf: block)
            }
            block = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[hooks]]" {
                flush()
                inHooksBlock = true
                block = [line]
            } else if inHooksBlock, trimmed.hasPrefix("[") {
                flush()
                inHooksBlock = false
                kept.append(line)
            } else if inHooksBlock {
                block.append(line)
            } else {
                kept.append(line)
            }
        }
        flush()
        return kept.joined(separator: "\n")
    }
}

/// OpenCode's opencode.json(c): a "plugin" array of module specs. The
/// plugin file itself lives in ~/.config/opencode/plugins/. Files with
/// comments are refused rather than rewritten, since a JSON round-trip
/// would eat them.
enum OpenCodeConfigTransform {
    static func isInstalled(_ text: String) -> Bool {
        text.contains("swarmbar")
    }

    static func install(_ text: String, pluginSpec: String) throws -> String {
        var root = try parse(text)
        var plugins = (root["plugin"] as? [String] ?? []).filter { !$0.contains("swarmbar") }
        plugins.append(pluginSpec)
        root["plugin"] = plugins
        return try serialize(root)
    }

    static func uninstall(_ text: String) throws -> String {
        var root = try parse(text)
        let plugins = (root["plugin"] as? [String] ?? []).filter { !$0.contains("swarmbar") }
        root["plugin"] = plugins.isEmpty ? nil : plugins
        return try serialize(root)
    }

    private static func parse(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw IntegrationTransformError.unparseable(
                "opencode config could not be parsed (comments in .jsonc are not supported); edit it by hand")
        }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
