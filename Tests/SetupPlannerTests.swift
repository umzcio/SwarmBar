import Foundation
import Testing
@testable import SwarmBar

/// Synthetic probes only: every host, user and path here is made up.
@Suite struct SetupPlannerTests {
    private static let bridges = BundledBridges(
        claudeHook: "#!/bin/sh\n# swarmbar-remote-bridge-v1 claude\n",
        kimiHook: "#!/bin/sh\n# swarmbar-remote-bridge-v1 kimi\n",
        openCodePlugin: "// swarmbar-remote-bridge-v1 opencode\n")
    private static let helperSHA = String(repeating: "ab", count: 32)

    static func sha(_ text: String) -> String { HelperInstaller.sha256(Data(text.utf8)) }

    static func config(
        _ tool: String, _ path: String, _ text: String?, dev: UInt64? = nil, ino: UInt64? = nil
    ) -> ProbeResult.ConfigFile {
        ProbeResult.ConfigFile(tool: tool, path: path, sha256: text.map(sha), text: text, dev: dev, ino: ino)
    }

    static func probe(
        user: String = "root", sudo: Bool = true, system: String = "Linux",
        homes: [String: String] = ["/root": "root"], tools: [String: [String]] = [:],
        installed: [String: [String]] = [:], unknown: [String: [String]] = [:],
        configs: [String: [ProbeResult.ConfigFile]] = [:]
    ) -> ProbeResult {
        ProbeResult(
            alias: "devbox", protocolVersion: 3, system: system, python: "3.12.3", hostname: "devbox",
            user: user, euid: user == "root" ? 0 : 1000, sudoOK: sudo,
            homes: homes.keys.sorted().map { RemoteHome(path: $0, user: homes[$0]!) },
            processes: [], tools: tools, installed: installed, installedUnknown: unknown,
            configs: configs)
    }

    static func plan(
        _ probe: ProbeResult, watchAs: WatchAs = .everyUser, kimiEvents: [String: [String]] = [:]
    ) throws -> SetupPlan {
        try SetupPlanner.plan(probe: probe, watchAs: watchAs, bundled: bridges, kimiEvents: kimiEvents)
    }

    static func newText(_ change: PlannedChange) -> String? {
        if case .write(let text, _) = change.action { return text }
        return nil
    }

    static func change(_ plan: SetupPlan, at path: String) -> PlannedChange? {
        plan.changes.first { $0.path == path }
    }

    static func text(_ plan: SetupPlan, at path: String) -> String? {
        change(plan, at: path).flatMap(newText)
    }

    // MARK: Planning

    @Test func rootPlanCoversEveryClaudeRootOnce() throws {
        // Two Claude roots, one symlinked to the other, both name the same
        // realpath. One write for the shared file, never two.
        let settings = #"{"model": "x"}"# + "\n"
        let probe = Self.probe(
            homes: ["/root": "root", "/home/u": "u"],
            tools: ["/root": ["claude"], "/home/u": ["claude"]],
            configs: [
                "/root": [Self.config("claude", "/root/.claude/settings.json", settings),
                          Self.config("claude", "/root/.claude/settings.json", settings)],
                "/home/u": [Self.config("claude", "/home/u/.claude/settings.json", "{}\n")],
            ])
        let plan = try Self.plan(probe)
        let paths = plan.changes.map(\.path)
        #expect(paths.filter { $0 == "/root/.claude/settings.json" }.count == 1)
        #expect(paths.contains("/home/u/.claude/settings.json"))
        #expect(paths.contains("/root/.swarmbar/swarmbar-remote-hook.sh"))
        #expect(paths.contains("/home/u/.swarmbar/swarmbar-remote-hook.sh"))
        // Bridge files go first, so a config never names a missing script.
        let firstConfig = try #require(paths.firstIndex { $0.hasSuffix("settings.json") })
        let lastScript = try #require(paths.lastIndex { $0.hasSuffix(".sh") })
        #expect(lastScript < firstConfig)

        let root = try #require(Self.change(plan, at: "/root/.claude/settings.json"))
        #expect(root.tool == .claudeCode)
        #expect(root.expectSHA256 == Self.sha(settings))
        #expect(root.description == "Add 4 hook entries to /root/.claude/settings.json")
        let text = try #require(Self.newText(root))
        #expect(text.contains("bash '/root/.swarmbar/swarmbar-remote-hook.sh' PermissionRequest"))
        #expect(text.contains("\"model\""))

        let script = try #require(Self.change(plan, at: "/root/.swarmbar/swarmbar-remote-hook.sh"))
        #expect(script.action == .write(newText: Self.bridges.claudeHook, mode: 0o700))
        #expect(script.expectSHA256 == "absent")
    }

    @Test func missingSettingsIsCreatedWithAbsentHash() throws {
        let plan = try Self.plan(Self.probe(tools: ["/root": ["claude"]]))
        let change = try #require(Self.change(plan, at: "/root/.claude/settings.json"))
        #expect(change.expectSHA256 == "absent")
        let text = try #require(Self.newText(change))
        #expect(text == (try ClaudeHookTransform.install(
            "{}\n", scriptPath: "/root/.swarmbar/swarmbar-remote-hook.sh", family: .remote)))
        if case .write(_, let mode) = change.action { #expect(mode == 0o600) }
    }

    @Test func missingTomlAndOpenCodeConfigsAreCreated() throws {
        let plan = try Self.plan(Self.probe(tools: ["/root": ["kimi", "bearcode", "opencode"]]))
        let kimi = try #require(Self.change(plan, at: "/root/.kimi-code/config.toml"))
        #expect(kimi.expectSHA256 == "absent")
        #expect(Self.newText(kimi) == TomlHooksTransform.install(
            "", scriptPath: "/root/.swarmbar/swarmbar-remote-kimi-hook.sh", family: .remote))
        #expect(Self.change(plan, at: "/root/.bearcode/config.toml")?.tool == .bearCode)
        let opencode = try #require(Self.change(plan, at: "/root/.config/opencode/opencode.json"))
        #expect(opencode.expectSHA256 == "absent")
        #expect(Self.newText(opencode)?.contains("file:///root/.config/opencode/plugins/swarmbar-remote.js")
            == true)
        let plugin = try #require(Self.change(plan, at: "/root/.config/opencode/plugins/swarmbar-remote.js"))
        #expect(plugin.action == .write(newText: Self.bridges.openCodePlugin, mode: 0o600))
        // One Kimi script serves both Kimi-family tools.
        #expect(plan.changes.filter { $0.path == "/root/.swarmbar/swarmbar-remote-kimi-hook.sh" }.count == 1)
    }

    @Test func loginUserPlanTouchesOnlyOwnHome() throws {
        let probe = Self.probe(
            user: "u", sudo: false, homes: ["/root": "root", "/home/u": "u"],
            tools: ["/root": ["claude", "kimi"], "/home/u": ["claude", "opencode"]])
        let plan = try Self.plan(probe, watchAs: .loginUser)
        #expect(!plan.changes.isEmpty)
        #expect(plan.changes.allSatisfy { $0.path.hasPrefix("/home/u/") })
        #expect(plan.installHelper == false)
        #expect(plan.sudoersUser == nil)
    }

    @Test func loginUserWithoutAHomeIsAnError() {
        let probe = Self.probe(user: "u", sudo: false, homes: ["/root": "root"], tools: ["/root": ["claude"]])
        #expect(throws: SetupPlanner.PlanError.self) { try Self.plan(probe, watchAs: .loginUser) }
    }

    @Test func narrowRulePlanInstallsHelperAndSudoers() throws {
        let narrow = try Self.plan(Self.probe(user: "u", sudo: false, homes: ["/home/u": "u"]))
        #expect(narrow.installHelper)
        #expect(narrow.sudoersUser == "u")
        #expect(narrow.helperDestination == HelperLaunch.rootHelperPath)

        let sudo = try Self.plan(Self.probe(user: "u", sudo: true, homes: ["/home/u": "u"]))
        #expect(!sudo.installHelper)
        #expect(sudo.sudoersUser == nil)

        let login = try Self.plan(Self.probe(user: "u", sudo: false, homes: ["/home/u": "u"]), watchAs: .loginUser)
        #expect(login.sudoersUser == nil)
        #expect(login.helperDestination == "/home/u/.swarmbar/swarmbar-helper")
    }

    @Test func kimiPlanNarrowsToAcceptedEvents() throws {
        let accepted = ["PermissionRequest", "PermissionResult", "PreToolUse", "Stop", "SessionEnd"]
        let probe = Self.probe(
            tools: ["/root": ["kimi"]],
            configs: ["/root": [Self.config("kimi", "/root/.kimi-code/config.toml", "[providers]\n")]])
        let plan = try Self.plan(probe, kimiEvents: ["/usr/local/bin/kimi": accepted])
        let change = try #require(Self.change(plan, at: "/root/.kimi-code/config.toml"))
        let text = try #require(Self.newText(change))
        #expect(text.contains("event = \"Stop\""))
        #expect(!text.contains("UserPromptSubmit"))
        #expect(text.hasPrefix("[providers]"))
        #expect(change.description
            == "Add 5 hook entries to /root/.kimi-code/config.toml. Left out because this build doesn't accept it: UserPromptSubmit")

        // A build that accepts every event gets the plain line.
        let all = TomlHooksTransform.events.map(\.name) + ["TurnStarted"]
        let full = try Self.plan(probe, kimiEvents: ["/usr/local/bin/kimi": all])
        #expect(Self.change(full, at: "/root/.kimi-code/config.toml")?.description
            == "Add 6 hook entries to /root/.kimi-code/config.toml")
    }

    @Test func emptyAcceptedEventsSkipTheTool() throws {
        let probe = Self.probe(
            tools: ["/root": ["kimi", "bearcode"]],
            configs: ["/root": [Self.config("kimi", "/root/.kimi-code/config.toml", "[providers]\n")]])
        let plan = try Self.plan(probe, kimiEvents: ["/opt/kimi/bin/kimi": ["SomethingElse"]])
        let kimi = try #require(Self.change(plan, at: "/root/.kimi-code/config.toml"))
        #expect(kimi.action == .skipped)
        #expect(kimi.description.contains("accepts none of SwarmBar's hook events"))
        // BearCode is a different build and is still planned, with its script.
        #expect(Self.text(plan, at: "/root/.bearcode/config.toml") != nil)
        #expect(Self.change(plan, at: "/root/.swarmbar/swarmbar-remote-kimi-hook.sh") != nil)

        let neither = try Self.plan(probe, kimiEvents: ["kimi": [], "/usr/local/bin/bearcode": []])
        #expect(neither.changes.allSatisfy { $0.action == .skipped })
        #expect(Self.change(neither, at: "/root/.swarmbar/swarmbar-remote-kimi-hook.sh") == nil)
    }

    @Test func jsoncWithCommentsIsLeftForHandEdit() throws {
        let jsonc = "{\n  // mine\n  \"plugin\": []\n}\n"
        let probe = Self.probe(
            tools: ["/root": ["claude", "opencode"]],
            configs: ["/root": [Self.config("opencode", "/root/.config/opencode/opencode.jsonc", jsonc),
                                Self.config("claude", "/root/.claude/settings.json", "{}\n")]])
        let plan = try Self.plan(probe)
        let opencode = try #require(Self.change(plan, at: "/root/.config/opencode/opencode.jsonc"))
        #expect(opencode.action == .byHand)
        #expect(opencode.description.hasPrefix("Edit by hand: /root/.config/opencode/opencode.jsonc has comments"))
        #expect(opencode.description.contains("file:///root/.config/opencode/plugins/swarmbar-remote.js"))
        // Everything else is still planned.
        #expect(Self.text(plan, at: "/root/.claude/settings.json") != nil)
        #expect(Self.change(plan, at: "/root/.config/opencode/plugins/swarmbar-remote.js") != nil)
    }

    @Test func hardlinkedConfigsArePlannedOnce() throws {
        // Two realpaths, one inode: a second write would find its hash gone.
        let probe = Self.probe(
            tools: ["/root": ["claude"]],
            configs: ["/root": [
                Self.config("claude", "/root/.claude/settings.json", "{}\n", dev: 7, ino: 42),
                Self.config("claude", "/root/.claude-work/settings.json", "{}\n", dev: 7, ino: 42),
                Self.config("claude", "/root/.claude-other/settings.json", "{}\n", dev: 8, ino: 42),
            ]])
        let configs = try Self.plan(probe).changes.filter { $0.path.hasSuffix("settings.json") }
        #expect(configs.map(\.path) == ["/root/.claude/settings.json", "/root/.claude-other/settings.json"])
    }

    @Test func unreadableConfigIsLeftForHandEdit() throws {
        let probe = Self.probe(
            tools: ["/root": ["claude", "kimi"]],
            configs: ["/root": [
                ProbeResult.ConfigFile(tool: "claude", path: "/root/.claude/settings.json", sha256: nil, text: nil),
                Self.config("kimi", "/root/.kimi-code/config.toml", ""),
            ]])
        let plan = try Self.plan(probe)
        let claude = try #require(Self.change(plan, at: "/root/.claude/settings.json"))
        #expect(claude.action == .byHand)
        #expect(claude.description.hasPrefix("Edit by hand: SwarmBar couldn't read /root/.claude/settings.json"))
        #expect(Self.text(plan, at: "/root/.kimi-code/config.toml") != nil)
    }

    @Test func configAlreadySetUpNeedsNoChange() throws {
        let script = "/root/.swarmbar/swarmbar-remote-hook.sh"
        let done = try ClaudeHookTransform.install("{}\n", scriptPath: script, family: .remote)
        let probe = Self.probe(
            tools: ["/root": ["claude"]], installed: ["/root": ["claude"]],
            configs: ["/root": [Self.config("claude", "/root/.claude/settings.json", done)]])
        #expect(try Self.plan(probe).changes.isEmpty)
    }

    @Test func undoPlanRemovesOnlyRemoteEntries() throws {
        let local = try ClaudeHookTransform.install(
            "{}\n", scriptPath: "/root/Library/Application Support/SwarmBar/swarmbar-hook.sh")
        let both = try ClaudeHookTransform.install(
            local, scriptPath: "/root/.swarmbar/swarmbar-remote-hook.sh", family: .remote)
        let toml = TomlHooksTransform.install(
            TomlHooksTransform.install("[providers]\n", scriptPath: "/opt/swarmbar-kimi-hook.sh"),
            scriptPath: "/root/.swarmbar/swarmbar-remote-kimi-hook.sh", family: .remote)
        let probe = Self.probe(
            tools: ["/root": ["claude", "kimi", "opencode"]],
            installed: ["/root": ["claude", "kimi", "opencode"]],
            configs: ["/root": [
                Self.config("claude", "/root/.claude/settings.json", both),
                Self.config("kimi", "/root/.kimi-code/config.toml", toml),
                Self.config("opencode", "/root/.config/opencode/opencode.json",
                            #"{"plugin": ["file:///x/swarmbar.js", "file:///root/.config/opencode/plugins/swarmbar-remote.js"]}"#),
            ]])
        let plan = try SetupPlanner.undoPlan(probe: probe, watchAs: .everyUser)
        #expect(!plan.installHelper)
        #expect(plan.sudoersUser == nil)

        let claude = try #require(Self.text(plan, at: "/root/.claude/settings.json"))
        #expect(claude == local)
        let kimi = try #require(Self.text(plan, at: "/root/.kimi-code/config.toml"))
        #expect(kimi.contains("swarmbar-kimi-hook.sh"))
        #expect(!kimi.contains("swarmbar-remote"))
        let opencode = try #require(Self.text(plan, at: "/root/.config/opencode/opencode.json"))
        #expect(opencode.contains("file:///x/swarmbar.js"))
        #expect(!opencode.contains("swarmbar-remote"))

        let removed = plan.changes.filter { $0.action == .remove }.map(\.path)
        #expect(removed == ["/root/.swarmbar/swarmbar-remote-hook.sh",
                            "/root/.swarmbar/swarmbar-remote-kimi-hook.sh",
                            "/root/.config/opencode/plugins/swarmbar-remote.js"])
        // Configs are edited back before the files they name go away.
        #expect(plan.changes.last?.action == .remove)
        #expect(plan.changes.first?.action != .remove)
    }

    @Test func undoKeepsABridgeFileWhoseConfigNeedsAHandEdit() throws {
        let jsonc = "{\n  // mine\n  \"plugin\": [\"file:///root/.config/opencode/plugins/swarmbar-remote.js\"]\n}\n"
        let probe = Self.probe(
            tools: ["/root": ["opencode"]], installed: ["/root": ["opencode"]],
            configs: ["/root": [Self.config("opencode", "/root/.config/opencode/opencode.jsonc", jsonc)]])
        let plan = try SetupPlanner.undoPlan(probe: probe, watchAs: .everyUser)
        let change = try #require(Self.change(plan, at: "/root/.config/opencode/opencode.jsonc"))
        #expect(change.action == .byHand)
        #expect(Self.change(plan, at: "/root/.config/opencode/plugins/swarmbar-remote.js") == nil)
    }

    // MARK: The command

    private static func operations(in command: String) throws -> [[String: Any]] {
        let start = try #require(command.range(of: " apply '"))
        let rest = command[start.upperBound...]
        let end = try #require(rest.firstIndex(of: "'"))
        let packed = try #require(Data(base64Encoded: String(rest[..<end])))
        let json = try (packed as NSData).decompressed(using: .zlib) as Data
        return try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
    }

    @Test func commandPinsVersionAndChecksum() throws {
        let narrow = try Self.plan(Self.probe(
            user: "u", sudo: false, homes: ["/home/u": "u"], tools: ["/home/u": ["claude"]]))
        let linux = SetupCommand.command(plan: narrow, system: "Linux", version: "0.2.0", helperSHA256: Self.helperSHA)
        #expect(linux.contains("https://github.com/umzcio/SwarmBar/releases/download/v0.2.0/swarmbar-helper.py"))
        #expect(linux.contains("echo \"\(Self.helperSHA)  $d/swarmbar-helper.py\" | sha256sum -c -"))
        #expect(linux.contains("&& sudo python3 -B \"$d/swarmbar-helper.py\" apply '"))
        #expect(!linux.contains("\n"))

        let ops = try Self.operations(in: linux)
        #expect(ops.first?["op"] as? String == "install_helper")
        #expect(ops.first?["dest"] as? String == HelperLaunch.rootHelperPath)
        #expect(ops.first?["expect_sha256"] as? String == Self.helperSHA)
        #expect(ops[1]["op"] as? String == "sudoers")
        #expect(ops[1]["user"] as? String == "u")
        let writes = ops.filter { $0["op"] as? String == "write_file" }
        #expect(writes.count == narrow.changes.count)
        let settings = try #require(writes.first { $0["path"] as? String == "/home/u/.claude/settings.json" })
        #expect(settings["expect_sha256"] as? String == "absent")
        #expect(settings["mode"] as? Int == 0o600)
        let encoded = try #require(settings["content_b64"] as? String)
        let bytes = try #require(Data(base64Encoded: encoded))
        #expect(String(decoding: bytes, as: UTF8.self)
            == Self.text(narrow, at: "/home/u/.claude/settings.json"))

        let login = try Self.plan(Self.probe(user: "u", sudo: false, homes: ["/home/u": "u"],
                                             tools: ["/home/u": ["claude"]]), watchAs: .loginUser)
        let darwin = SetupCommand.command(plan: login, system: "Darwin", version: "0.2.0", helperSHA256: Self.helperSHA)
        #expect(darwin.contains("| shasum -a 256 -c -"))
        #expect(!darwin.contains("sudo "))
        #expect(try Self.operations(in: darwin).allSatisfy {
            !["install_helper", "sudoers"].contains($0["op"] as? String) })
    }

    @Test func commandDownloadsIntoAFreshDirectory() throws {
        let plan = try Self.plan(Self.probe(tools: ["/root": ["claude"]]))
        let command = SetupCommand.command(plan: plan, system: "Linux", version: "0.2.0", helperSHA256: Self.helperSHA)
        #expect(command.hasPrefix("d=$(mktemp -d) && curl -fsSL "))
        #expect(command.contains("-o \"$d/swarmbar-helper.py\""))
        #expect(command.hasSuffix("; rm -rf \"$d\""))
        #expect(!command.contains("/tmp/swarmbar-helper.py"))
    }

    @Test func commandLeavesOutHandEdits() throws {
        let probe = Self.probe(
            tools: ["/root": ["opencode"]],
            configs: ["/root": [Self.config("opencode", "/root/.config/opencode/opencode.jsonc", "{ // c\n}\n")]])
        let plan = try Self.plan(probe)
        let ops = try Self.operations(in: SetupCommand.command(
            plan: plan, system: "Linux", version: "0.2.0", helperSHA256: Self.helperSHA))
        #expect(ops.map { $0["path"] as? String } == ["/root/.config/opencode/plugins/swarmbar-remote.js"])
    }

    @Test func everyUserWarningSaysItIsRootEquivalent() {
        #expect(SetupCommand.everyUserWarning(user: "u")
            == "This lets u act as root through SwarmBar's helper. Only set this up for an account you'd trust with root.")
    }

    // MARK: The prompt

    @Test func promptNamesEveryPathAndHash() throws {
        let settings = "{}\n"
        let probe = Self.probe(
            homes: ["/root": "root"], tools: ["/root": ["claude", "kimi"]],
            configs: ["/root": [Self.config("claude", "/root/.claude/settings.json", settings)]])
        let plan = try Self.plan(probe)
        let prompt = SetupCommand.prompt(plan: plan, hostName: "devbox")
        #expect(prompt.contains("devbox"))
        for change in plan.changes {
            #expect(prompt.contains(change.path))
            if case .write(let text, _) = change.action { #expect(prompt.contains(text)) }
        }
        #expect(prompt.contains(Self.sha(settings)))
        #expect(prompt.contains("/root/.claude/settings.json.backup-swarmbar"))
        #expect(prompt.contains("must not exist"))
        #expect(prompt.contains("grep -c swarmbar-remote /root/.claude/settings.json"))
        #expect(prompt.contains("stop"))
        #expect(!prompt.contains("\u{2014}"))
    }

    @Test func promptNeverWritesTheSudoRule() throws {
        let plan = try Self.plan(Self.probe(
            user: "u", sudo: false, homes: ["/home/u": "u"], tools: ["/home/u": ["claude"]]))
        #expect(plan.sudoersUser == "u")
        let prompt = SetupCommand.prompt(plan: plan, hostName: "devbox")
        #expect(!prompt.contains("sudoers"))
        #expect(!prompt.contains("NOPASSWD"))
        #expect(!prompt.contains(HelperLaunch.rootHelperPath))
        #expect(prompt.contains("setup command"))
        #expect(!prompt.contains("\u{2014}"))
    }

    @Test func promptFenceOutlastsBackticksInTheContent() throws {
        let plan = SetupPlan(
            changes: [PlannedChange(tool: nil, path: "/root/.swarmbar/swarmbar-remote-hook.sh",
                                    expectSHA256: "absent",
                                    action: .write(newText: "a ``` b\n", mode: 0o700), description: "x")],
            installHelper: false, sudoersUser: nil)
        #expect(SetupCommand.prompt(plan: plan, hostName: "devbox").contains("````\na ``` b\n````"))
    }

    @Test func bundledBridgesLoadFromTheApp() throws {
        let bundled = try #require(BundledBridges.load())
        #expect(bundled.claudeHook.contains("swarmbar-remote-bridge"))
        #expect(bundled.kimiHook.contains("swarmbar-remote-bridge"))
        #expect(bundled.openCodePlugin.contains("swarmbar-remote-bridge"))
    }
}

/// SetupApplier against the real helper, run locally over a real channel,
/// in a temporary home.
@Suite struct SetupApplierTests {
    private static func realpath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @MainActor
    @Test func changedFileStopsOnlyThatFile() async throws {
        let python = "/usr/bin/python3"
        try #require(FileManager.default.isExecutableFile(atPath: python))
        let script = try #require(Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"))
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("swarmbar-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        let home = Self.realpath(made.path)

        let originals = [
            ("claude", "\(home)/.claude/settings.json", "{}\n"),
            ("kimi", "\(home)/.kimi-code/config.toml", "[providers]\n"),
            ("opencode", "\(home)/.config/opencode/opencode.json", "{}\n"),
        ]
        var configs: [ProbeResult.ConfigFile] = []
        for (tool, path, text) in originals {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: false, encoding: .utf8)
            configs.append(SetupPlannerTests.config(tool, path, text))
        }
        let probe = SetupPlannerTests.probe(
            user: NSUserName(), sudo: false, homes: [home: NSUserName()],
            tools: [home: ["claude", "kimi", "opencode"]], configs: [home: configs])
        let plan = try SetupPlanner.plan(
            probe: probe, watchAs: .loginUser, bundled: try #require(BundledBridges.load()), kimiEvents: [:])

        // Someone edits the Kimi config between the plan and the apply.
        let edited = "[providers]\n# edited by hand\n"
        try edited.write(toFile: originals[1].1, atomically: false, encoding: .utf8)

        let channel = SSHChannel(launch: .local(python: python, script: script.path, homes: [home]))
        let applier = SetupApplier(connection: channel)
        var outcomes: [Int: SetupApplier.StepOutcome] = [:]
        await applier.apply(plan) { index, outcome in outcomes[index] = outcome }
        await channel.shutdown()

        #expect(outcomes.count == plan.changes.count)
        let configOutcomes = originals.map { original in
            plan.changes.firstIndex { $0.path == original.1 }.flatMap { outcomes[$0] }
        }
        #expect(configOutcomes == [.done, .changed, .done])
        for (index, change) in plan.changes.enumerated() where change.path != originals[1].1 {
            #expect(outcomes[index] == .done, "\(change.path)")
        }
        #expect(try String(contentsOfFile: originals[1].1, encoding: .utf8) == edited)
        #expect(try String(contentsOfFile: originals[0].1, encoding: .utf8).contains("swarmbar-remote-hook.sh"))
        #expect(try String(contentsOfFile: originals[2].1, encoding: .utf8).contains("swarmbar-remote.js"))
        #expect(FileManager.default.fileExists(atPath: "\(home)/.swarmbar/swarmbar-remote-hook.sh"))
    }

    /// The command's blob, run through the real helper's `apply`, which
    /// is the only reader that matters for Foundation's raw deflate.
    @Test func commandBlobAppliesWithTheRealHelper() throws {
        let python = "/usr/bin/python3"
        try #require(FileManager.default.isExecutableFile(atPath: python))
        let script = try #require(Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"))
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("swarmbar-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        let home = Self.realpath(made.path)

        let probe = SetupPlannerTests.probe(
            user: NSUserName(), sudo: false, homes: [home: NSUserName()], tools: [home: ["claude"]])
        let plan = try SetupPlanner.plan(
            probe: probe, watchAs: .loginUser, bundled: try #require(BundledBridges.load()), kimiEvents: [:])
        let command = SetupCommand.command(plan: plan, system: "Darwin", version: "0.2.0", helperSHA256: "x")
        let start = try #require(command.range(of: " apply '"))
        let blob = String(command[start.upperBound...].prefix { $0 != "'" })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script.path, "apply", blob]
        process.environment = ["SWARMBAR_HELPER_HOMES": home, "HOME": home, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(said)")
        #expect(said.components(separatedBy: "\n").filter { $0.hasPrefix("ok: write_file") }.count == 2)
        let settings = try String(contentsOfFile: "\(home)/.claude/settings.json", encoding: .utf8)
        #expect(settings.contains("\(home)/.swarmbar/swarmbar-remote-hook.sh"))
        let attributes = try FileManager.default.attributesOfItem(atPath: "\(home)/.swarmbar/swarmbar-remote-hook.sh")
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @MainActor
    @Test func handEditsAreNeverSent() async throws {
        let python = "/usr/bin/python3"
        try #require(FileManager.default.isExecutableFile(atPath: python))
        let script = try #require(Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"))
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("swarmbar-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }
        let home = Self.realpath(made.path)
        let plan = SetupPlan(changes: [
            PlannedChange(tool: .openCode, path: "\(home)/.config/opencode/opencode.jsonc", expectSHA256: "",
                          action: .byHand, description: "Edit by hand"),
            PlannedChange(tool: .kimiCode, path: "\(home)/.kimi-code/config.toml", expectSHA256: "",
                          action: .skipped, description: "Skipped"),
        ], installHelper: false, sudoersUser: nil)
        let channel = SSHChannel(launch: .local(python: python, script: script.path, homes: [home]))
        var outcomes: [Int: SetupApplier.StepOutcome] = [:]
        await SetupApplier(connection: channel).apply(plan) { index, outcome in outcomes[index] = outcome }
        await channel.shutdown()
        #expect(outcomes == [0: .failed("edit by hand"), 1: .failed("skipped")])
        #expect(!FileManager.default.fileExists(atPath: "\(home)/.config"))
    }
}
