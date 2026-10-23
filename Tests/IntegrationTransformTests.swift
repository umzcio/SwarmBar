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

    /// A "plugin" list holding anything but plain names (a [name, options]
    /// pair, say) is a hand edit. Reading it as [String] used to fail and
    /// fall back to an empty list, so install replaced the user's plugins
    /// with SwarmBar's and uninstall deleted them all.
    @Test func pluginListThatIsNotPlainNamesIsRefused() throws {
        let tuple = #"{"plugin": ["some-plugin", ["other-plugin", {"opt": true}]]}"#
        let withOurs = #"{"plugin": ["file:///x/swarmbar.js", ["other-plugin", {"opt": true}]]}"#
        for family in [BridgeFamily.local, .remote] {
            #expect(throws: IntegrationTransformError.self) {
                _ = try OpenCodeConfigTransform.install(tuple, pluginSpec: "file:///x/swarmbar.js", family: family)
            }
            #expect(throws: IntegrationTransformError.self) {
                _ = try OpenCodeConfigTransform.uninstall(withOurs, family: family)
            }
        }
        for odd in [#"{"plugin": "file:///x/swarmbar.js"}"#, #"{"plugin": [1, 2]}"#, #"{"plugin": {"a": 1}}"#] {
            #expect(throws: IntegrationTransformError.self) {
                _ = try OpenCodeConfigTransform.install(odd, pluginSpec: "file:///x/swarmbar.js")
            }
            #expect(throws: IntegrationTransformError.self) { _ = try OpenCodeConfigTransform.uninstall(odd) }
        }
        // Ours still reads as installed beside a pair.
        #expect(OpenCodeConfigTransform.isInstalled(withOurs))
        // A null list is no list.
        let fromNull = try OpenCodeConfigTransform.install(#"{"plugin": null}"#, pluginSpec: "file:///x/swarmbar.js")
        #expect(OpenCodeConfigTransform.isInstalled(fromNull))
    }

    @Test func commentedJsoncThrows() {
        #expect(throws: IntegrationTransformError.self) {
            _ = try OpenCodeConfigTransform.install(
                "// my config\n{\"a\": 1}", pluginSpec: "file:///x/swarmbar.js")
        }
    }
}

struct BridgeFamilyTransformTests {
    let claudeRemote = "/root/.swarmbar/swarmbar-remote-hook.sh"
    let claudeLocal = "/Users/x/Library/Application Support/SwarmBar/swarmbar-hook.sh"
    let kimiRemote = "/home/u/.swarmbar/swarmbar-remote-kimi-hook.sh"
    let kimiLocal = "/Users/x/Library/Application Support/SwarmBar/swarmbar-kimi-hook.sh"

    private func both() throws -> String {
        let local = try ClaudeHookTransform.install("{}", scriptPath: claudeLocal)
        return try ClaudeHookTransform.install(local, scriptPath: claudeRemote, family: .remote)
    }

    @Test func familyPredicate() {
        #expect(BridgeFamily.remote.owns("bash '/root/.swarmbar/swarmbar-remote-hook.sh' Stop"))
        #expect(!BridgeFamily.local.owns("bash '/root/.swarmbar/swarmbar-remote-hook.sh' Stop"))
        #expect(BridgeFamily.local.owns("bash '/a/swarmbar-hook.sh' Stop"))
        #expect(!BridgeFamily.remote.owns("bash '/a/swarmbar-hook.sh' Stop"))
    }

    @Test func localUninstallKeepsRemoteClaudeEntries() throws {
        let out = try ClaudeHookTransform.uninstall(try both())
        #expect(!ClaudeHookTransform.isInstalled(out))
        #expect(ClaudeHookTransform.isInstalled(out, family: .remote))
        #expect(out.contains("swarmbar-remote-hook.sh' PermissionRequest"))
    }

    @Test func remoteUninstallKeepsLocalClaudeEntries() throws {
        let out = try ClaudeHookTransform.uninstall(try both(), family: .remote)
        #expect(ClaudeHookTransform.isInstalled(out))
        #expect(!ClaudeHookTransform.isInstalled(out, family: .remote))
        #expect(!out.contains("swarmbar-remote"))
    }

    @Test func bothFamiliesCoexistInOneSettingsFile() throws {
        let out = try both()
        let data = try #require(out.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
        let commands = hooks.values.flatMap { $0 }.flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
            .compactMap { $0["command"] as? String }
        #expect(commands.count == 8)
        #expect(commands.filter(BridgeFamily.local.owns).count == 4)
        #expect(commands.filter(BridgeFamily.remote.owns).count == 4)
    }

    @Test func localInstallDoesNotReportRemoteOnly() throws {
        let remoteOnly = try ClaudeHookTransform.install("{}", scriptPath: claudeRemote, family: .remote)
        #expect(!ClaudeHookTransform.isInstalled(remoteOnly))
    }

    @Test func remoteTomlBlockUsesItsOwnMarkers() {
        let out = TomlHooksTransform.install("", scriptPath: kimiRemote, family: .remote)
        #expect(out.contains("# >>> SwarmBar remote hooks >>>"))
        #expect(out.contains("# <<< SwarmBar remote hooks <<<"))
        #expect(!out.contains(TomlHooksTransform.beginMarker))
        #expect(out.contains("command = \"'\(kimiRemote)' Stop\""))
        #expect(TomlHooksTransform.isInstalled(out, family: .remote))
        #expect(!TomlHooksTransform.isInstalled(out))
        let removed = TomlHooksTransform.uninstall(out, family: .remote)
        #expect(!removed.contains("[[hooks]]"))
    }

    @Test func localTomlSweepSparesRemoteBlock() {
        let manual = """
        [[hooks]]
        event = "Stop"
        command = "/x/swarmbar-kimi-hook.sh Stop"
        """
        let remote = TomlHooksTransform.install(manual, scriptPath: kimiRemote, family: .remote)
        let local = TomlHooksTransform.uninstall(remote)
        #expect(!local.contains("/x/swarmbar-kimi-hook.sh"))
        #expect(local.contains("# >>> SwarmBar remote hooks >>>"))
        #expect(local.contains("swarmbar-remote-kimi-hook.sh"))
        let reverse = TomlHooksTransform.uninstall(
            TomlHooksTransform.install(manual, scriptPath: kimiLocal), family: .remote)
        #expect(reverse.contains("swarmbar-kimi-hook.sh"))
    }

    @Test func tomlEventsCanBeNarrowed() {
        let out = TomlHooksTransform.install(
            "", scriptPath: kimiRemote, family: .remote,
            events: [("PermissionRequest", nil), ("Stop", 10)])
        #expect(out.components(separatedBy: "[[hooks]]").count - 1 == 2)
        #expect(out.contains("event = \"PermissionRequest\""))
        #expect(out.contains("event = \"Stop\""))
        #expect(!out.contains("PreToolUse"))
    }

    @Test func openCodeFamiliesCoexist() throws {
        let local = try OpenCodeConfigTransform.install(
            "{}", pluginSpec: "file:///Users/x/plugins/swarmbar.js")
        let both = try OpenCodeConfigTransform.install(
            local, pluginSpec: "file:///home/u/.config/opencode/plugins/swarmbar-remote.js", family: .remote)
        #expect(both.contains("plugins/swarmbar.js"))
        #expect(both.contains("swarmbar-remote.js"))
        let noLocal = try OpenCodeConfigTransform.uninstall(both)
        #expect(!OpenCodeConfigTransform.isInstalled(noLocal))
        #expect(OpenCodeConfigTransform.isInstalled(noLocal, family: .remote))
        let noRemote = try OpenCodeConfigTransform.uninstall(both, family: .remote)
        #expect(OpenCodeConfigTransform.isInstalled(noRemote))
        #expect(!noRemote.contains("swarmbar-remote"))
    }

    @Test func jsonWithoutHooksReadsNotInstalled() {
        let json = "{\"permissions\": {\"allow\": [\"Read(//Users/x/.swarmbar/**)\"]}}"
        #expect(!ClaudeHookTransform.isInstalled(json))
        #expect(!ClaudeHookTransform.isInstalled(json, family: .remote))
    }

    @Test func unparseableJSONFallsBackToScriptNames() {
        let text = "not json bash /x/swarmbar-hook.sh Stop"
        #expect(ClaudeHookTransform.isInstalled(text))
        #expect(!ClaudeHookTransform.isInstalled(text, family: .remote))
    }

    @Test func unclosedLocalMarkerSparesRemoteBlock() {
        let remote = TomlHooksTransform.install("", scriptPath: kimiRemote, family: .remote)
        let text = TomlHooksTransform.beginMarker + "\n[[hooks]]\nevent = \"Stop\"\ncommand = \"/x/swarmbar-kimi-hook.sh Stop\"\n\n" + remote
        let out = TomlHooksTransform.uninstall(text)
        #expect(out.contains("swarmbar-remote-kimi-hook.sh"))
        #expect(!out.contains("/x/swarmbar-kimi-hook.sh"))
    }

    @Test func emptyEventsWritesNoBlock() {
        let out = TomlHooksTransform.install("a = 1", scriptPath: kimiRemote, family: .remote, events: [])
        #expect(!out.contains("SwarmBar"))
        #expect(!TomlHooksTransform.isInstalled(out, family: .remote))
    }

    @Test func remoteFirstThenLocalThenLocalUninstall() {
        let r = TomlHooksTransform.install("", scriptPath: kimiRemote, family: .remote)
        let both = TomlHooksTransform.install(r, scriptPath: kimiLocal)
        #expect(TomlHooksTransform.isInstalled(both))
        #expect(TomlHooksTransform.isInstalled(both, family: .remote))
        let out = TomlHooksTransform.uninstall(both)
        #expect(!TomlHooksTransform.isInstalled(out))
        #expect(TomlHooksTransform.isInstalled(out, family: .remote))
        #expect(out.components(separatedBy: "[[hooks]]").count - 1 == TomlHooksTransform.events.count)
    }

    @Test func indentedMarkersAreRecognised() {
        let text = "  " + TomlHooksTransform.remoteBeginMarker + "\n[[hooks]]\nevent = \"Stop\"\ncommand = \"" + kimiRemote + " Stop\"\n  " + TomlHooksTransform.remoteEndMarker + "\n"
        #expect(TomlHooksTransform.isInstalled(text, family: .remote))
        #expect(!TomlHooksTransform.uninstall(text, family: .remote).contains("[[hooks]]"))
    }

    @Test func unmarkedRemoteTableSweptOnlyByRemote() {
        let text = "[[hooks]]\nevent = \"Stop\"\ncommand = \"" + kimiRemote + " Stop\"\n"
        #expect(TomlHooksTransform.isInstalled(text, family: .remote))
        #expect(!TomlHooksTransform.isInstalled(text))
        #expect(TomlHooksTransform.uninstall(text).contains("swarmbar-remote"))
        #expect(!TomlHooksTransform.uninstall(text, family: .remote).contains("swarmbar-remote"))
    }
}

/// Kimi and BearCode print a UserPromptSubmit hook's stdout into the
/// transcript (and hand it to the model as context), so the bridge's echoed
/// "{}" showed up under every prompt. The fixed script only reaches users if
/// the copy already installed in Application Support is refreshed.
struct BridgeScriptRefreshTests {
    @Test func anOutdatedInstalledScriptIsReplaced() {
        #expect(IntegrationManager.refreshedScript(installed: "old", bundled: "new") == "new")
    }

    @Test func aCurrentScriptIsLeftAlone() {
        #expect(IntegrationManager.refreshedScript(installed: "same", bundled: "same") == nil)
    }

    /// Never install on the user's behalf: no copy means the bridge was
    /// never switched on, and creating one would be an opt-in they did not make.
    @Test func aMissingScriptIsNotCreated() {
        #expect(IntegrationManager.refreshedScript(installed: nil, bundled: "new") == nil)
    }

    /// The Kimi family never needs SwarmBar's reply: every event is
    /// fire-and-forget and approvals go through the terminal.
    @Test func theKimiBridgePrintsNothing() throws {
        let url = try #require(Bundle.main.url(forResource: "swarmbar-kimi-hook", withExtension: "sh"))
        let script = try String(contentsOf: url, encoding: .utf8)
        let curl = try #require(script.components(separatedBy: "curl ").last)
        #expect(curl.contains(">/dev/null") || curl.contains("> /dev/null"))
    }
}
