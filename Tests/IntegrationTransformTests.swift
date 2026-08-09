import Foundation
import Testing
@testable import SwarmBar

@MainActor
struct ClaudeHookTransformTests {
    let bare = "{\"model\": \"opus\"}"

    @Test func installAddsAllFourEvents() throws {
        let out = try ClaudeHookTransform.install(bare, scriptPath: "/tmp/swarmbar-hook.sh")
        #expect(ClaudeHookTransform.isInstalled(out))
        for (event, timeout) in ClaudeHookTransform.events {
            #expect(out.contains("swarmbar-hook.sh' \(event)"))
            #expect(out.contains("\"timeout\" : \(timeout)"))
        }
        // Untouched settings survive.
        #expect(out.contains("\"model\""))
    }

    @Test func installIsIdempotentAndMovesScriptPath() throws {
        let once = try ClaudeHookTransform.install(bare, scriptPath: "/old/swarmbar-hook.sh")
        let twice = try ClaudeHookTransform.install(once, scriptPath: "/new/swarmbar-hook.sh")
        #expect(!twice.contains("/old/"))
        #expect(twice.contains("'/new/swarmbar-hook.sh' PermissionRequest"))
        // Exactly one entry per event.
        let occurrences = twice.components(separatedBy: "swarmbar-hook.sh' Stop").count - 1
        #expect(occurrences == 1)
    }

    @Test func uninstallRemovesOnlySwarmBarEntries() throws {
        let mixed = """
        {"hooks": {"Stop": [
            {"hooks": [{"type": "command", "command": "bash /x/other-tool.sh"}]},
            {"hooks": [{"type": "command", "command": "bash /x/swarmbar-hook.sh Stop"}]}
        ]}}
        """
        let out = try ClaudeHookTransform.uninstall(mixed)
        #expect(!ClaudeHookTransform.isInstalled(out))
        #expect(out.contains("other-tool.sh"))
    }

    @Test func invalidJSONThrows() {
        #expect(throws: IntegrationTransformError.self) {
            _ = try ClaudeHookTransform.install("not json {", scriptPath: "/x")
        }
    }

    @Test func installQuotesPathsWithSpaces() throws {
        let path = "/Users/x/Library/Application Support/SwarmBar/swarmbar-hook.sh"
        let out = try ClaudeHookTransform.install(bare, scriptPath: path)
        #expect(out.contains("bash '\(path)' PermissionRequest"))
        #expect(ClaudeHookTransform.isInstalled(out))
        // A prior install at the same spaced path is replaced, not duplicated.
        let twice = try ClaudeHookTransform.install(out, scriptPath: path)
        #expect(twice.components(separatedBy: "swarmbar-hook.sh' Stop").count - 1 == 1)
    }
}

@MainActor
struct TomlHooksTransformTests {
    let base = """
    default_model = "kimi-code/kimi-for-coding"

    [thinking]
    enabled = true
    """

    @Test func installAppendsMarkedBlock() {
        let out = TomlHooksTransform.install(base, scriptPath: "/tmp/swarmbar-kimi-hook.sh")
        #expect(TomlHooksTransform.isInstalled(out))
        #expect(out.contains(TomlHooksTransform.beginMarker))
        #expect(out.contains("command = \"'/tmp/swarmbar-kimi-hook.sh' PermissionRequest\""))
        #expect(out.contains("[thinking]"))
    }

    @Test func uninstallRestoresOriginal() {
        let installed = TomlHooksTransform.install(base, scriptPath: "/tmp/swarmbar-kimi-hook.sh")
        let out = TomlHooksTransform.uninstall(installed)
        #expect(!TomlHooksTransform.isInstalled(out))
        #expect(out.contains("[thinking]"))
        #expect(!out.contains("[[hooks]]"))
    }

    @Test func uninstallSweepsUnmarkedManualEntries() {
        let manual = base + """


        [[hooks]]
        event = "Stop"
        command = "/Users/example/GitHub/SwarmBar/scripts/swarmbar-kimi-hook.sh Stop"
        timeout = 5

        [[hooks]]
        event = "Stop"
        command = "/x/unrelated-hook.sh Stop"
        """
        let out = TomlHooksTransform.uninstall(manual)
        #expect(!out.contains("swarmbar"))
        #expect(out.contains("unrelated-hook.sh"))
    }

    @Test func installReplacesPriorInstall() {
        let once = TomlHooksTransform.install(base, scriptPath: "/old/swarmbar-kimi-hook.sh")
        let twice = TomlHooksTransform.install(once, scriptPath: "/new/swarmbar-kimi-hook.sh")
        #expect(!twice.contains("/old/"))
        let markers = twice.components(separatedBy: TomlHooksTransform.beginMarker).count - 1
        #expect(markers == 1)
    }

    @Test func installQuotesPathsWithSpaces() {
        let path = "/Users/x/Library/Application Support/SwarmBar/swarmbar-kimi-hook.sh"
        let out = TomlHooksTransform.install(base, scriptPath: path)
        #expect(out.contains("command = \"'\(path)' PermissionRequest\""))
        #expect(!TomlHooksTransform.uninstall(out).contains("swarmbar"))
        #expect(TomlHooksTransform.uninstall(out).contains("[thinking]"))
    }
}

@MainActor
struct OpenCodeConfigTransformTests {
    @Test func installAddsPluginEntry() throws {
        let out = try OpenCodeConfigTransform.install(
            "{\"$schema\": \"https://opencode.ai/config.json\"}",
            pluginSpec: "file:///x/plugins/swarmbar.js")
        #expect(OpenCodeConfigTransform.isInstalled(out))
        #expect(out.contains("file:///x/plugins/swarmbar.js"))
        #expect(out.contains("$schema"))
    }

    @Test func uninstallDropsEntryAndEmptyArray() throws {
        let installed = try OpenCodeConfigTransform.install("{}", pluginSpec: "file:///x/swarmbar.js")
        let out = try OpenCodeConfigTransform.uninstall(installed)
        #expect(!OpenCodeConfigTransform.isInstalled(out))
        #expect(!out.contains("\"plugin\""))
    }

    @Test func otherPluginsSurvive() throws {
        let config = "{\"plugin\": [\"some-other-plugin\"]}"
        let installed = try OpenCodeConfigTransform.install(config, pluginSpec: "file:///x/swarmbar.js")
        let removed = try OpenCodeConfigTransform.uninstall(installed)
        #expect(removed.contains("some-other-plugin"))
    }

    @Test func commentedJsoncThrows() {
        #expect(throws: IntegrationTransformError.self) {
            _ = try OpenCodeConfigTransform.install(
                "// my config\n{\"a\": 1}", pluginSpec: "file:///x/swarmbar.js")
        }
    }
}
