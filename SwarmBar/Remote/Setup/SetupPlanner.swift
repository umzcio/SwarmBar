import Foundation

/// One change the setup sheet lists, and the helper makes, on a host.
struct PlannedChange: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Replace the file's whole contents, or create it with `mode`.
        case write(newText: String, mode: Int)
        /// Delete one of SwarmBar's own bridge files.
        case remove
        /// Nothing is sent. A person has to make this change, and
        /// `description` says what it is and why SwarmBar can't.
        case byHand
        /// Nothing is sent and nothing is needed: `description` says why
        /// this tool is left out.
        case skipped
    }

    var tool: AgentTool?
    /// The realpath on the host.
    var path: String
    /// The sha256 the file must have before the write, or "absent" for a
    /// file that must not exist yet. Empty where nothing is checked: a
    /// removal, or a change that is never sent.
    var expectSHA256: String
    var action: Action
    /// The sheet's line, e.g. "Add 4 hook entries to /root/.claude/settings.json".
    var description: String
    /// Indexes of earlier changes in the same plan that must end done
    /// before this one is made: a config waits for the bridge file it
    /// names, and an undo's removal waits for the config that named it.
    var dependsOn: [Int] = []

    /// Whether the helper is asked to make this change at all.
    var isSent: Bool {
        switch action {
        case .write, .remove: true
        case .byHand, .skipped: false
        }
    }
}

struct SetupPlan: Equatable, Sendable {
    var changes: [PlannedChange]
    /// The helper goes in as part of the setup command, because nothing
    /// else can put root's copy in place without passwordless sudo.
    var installHelper: Bool
    /// Who gets the narrow sudo rule. Only ever set through the setup
    /// command, which a person runs with their own password.
    var sudoersUser: String?
    var watchAs: WatchAs = .everyUser
    /// Where `install_helper` puts the helper: root's copy when every user
    /// is watched, the login user's own otherwise. The helper refuses any
    /// other destination.
    var helperDestination: String = HelperLaunch.rootHelperPath
    /// The host's `platform.system()`, which picks the prompt's base64 flag.
    var system: String = "Linux"
    /// Whether the setup command runs `apply` under sudo.
    var useSudo: Bool = false
    /// The plan covers only what the login user could see of a host whose
    /// every user is watched: the narrow sudo rule is not there yet, so the
    /// other homes were never looked at. Probe again once it is.
    var isPartial: Bool = false
}

/// The three remote bridge files, as this build bundles them.
struct BundledBridges: Equatable, Sendable {
    var claudeHook: String
    var kimiHook: String
    var openCodePlugin: String

    static func load(from bundle: Bundle = .main) -> BundledBridges? {
        func text(_ name: String, _ ext: String) -> String? {
            bundle.url(forResource: name, withExtension: ext)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let claude = text("swarmbar-remote-hook", "sh"),
              let kimi = text("swarmbar-remote-kimi-hook", "sh"),
              let plugin = text("swarmbar-remote-opencode", "js")
        else { return nil }
        return BundledBridges(claudeHook: claude, kimiHook: kimi, openCodePlugin: plugin)
    }
}

/// Turns a host probe into exactly the config changes its approvals need,
/// or into their undo. Pure, so every case is tested against synthetic
/// probes. The texts come from the same transforms the local toggles use,
/// with the remote family, so the two families never touch each other's
/// entries.
enum SetupPlanner {
    enum PlanError: Error, Equatable {
        /// The probe listed no home to plan for. Could not look, which must
        /// not plan as nothing to do.
        case noHome(user: String)
    }

    static let absent = "absent"
    /// Agent configs can hold provider keys, so a new one is private.
    static let configMode = 0o600
    static let scriptMode = 0o700
    static let pluginMode = 0o600

    static func claudeScript(home: String) -> String { "\(home)/.swarmbar/swarmbar-remote-hook.sh" }
    static func kimiScript(home: String) -> String { "\(home)/.swarmbar/swarmbar-remote-kimi-hook.sh" }
    static func plugin(home: String) -> String { "\(home)/.config/opencode/plugins/swarmbar-remote.js" }
    static func pluginSpec(home: String) -> String { "file://\(plugin(home: home))" }

    /// The Kimi family, each with the helper's tool name and config dir.
    private static let tomlTools: [(tool: AgentTool, name: String, dir: String)] = [
        (.kimiCode, "kimi", ".kimi-code"),
        (.bearCode, "bearcode", ".bearcode"),
    ]

    /// A change before its dependencies are known by index: `needs` names
    /// the paths of the changes it waits for.
    private struct Pending {
        var change: PlannedChange
        var needs: [String] = []
    }

    /// `loginEUID` is the euid of the login user's own probe, the account
    /// that will paste the setup command. Pass it whenever `probe` is
    /// root's view, whose euid says nothing about who logs in. nil means
    /// `probe` is the login user's own.
    static func plan(
        probe: ProbeResult, watchAs: WatchAs, bundled: BundledBridges, kimiEvents: [String: [String]],
        loginEUID: Int? = nil
    ) throws -> SetupPlan {
        let homes = try watchedHomes(probe, watchAs)
        let owners = fileOwners(probe, homes)
        var bridges: [Pending] = []
        var configs: [Pending] = []
        var seen = Seen()

        for home in homes {
            let tools = Set(toolList(probe.tools[home.path]))
            let reported = probe.bridges?[home.path] ?? []
            // A file several homes share is planned once, from the home
            // whose owner owns it: that is where it was readable, and its
            // bridge path is the one that home's agents run.
            let files = (probe.configs[home.path] ?? []).filter { file in
                guard let key = Seen.key(file) else { return true }
                return owners[key] == home.path
            }

            if tools.contains(.claudeCode) {
                let script = claudeScript(home: home.path)
                // Every settings file there is, and one to create for each
                // used profile that has none. Never a guessed ~/.claude: a
                // profile the probe did not report is not known to exist.
                var targets: [(file: ProbeResult.ConfigFile?, path: String)] =
                    files.filter { $0.tool == "claude" }.map { ($0, $0.path) }
                for dir in probe.claudeDirs?[home.path] ?? [] where dir.settings == "missing" {
                    targets.append((nil, "\(dir.path)/settings.json"))
                }
                for target in targets {
                    let events = ClaudeHookTransform.events.map(\.name)
                    let change = configChange(
                        tool: .claudeCode, file: target.file, path: target.path, seed: "{}\n", seen: &seen,
                        description: "Add \(events.count) hook entries to \(target.path)",
                        instruction: "Add hooks for \(list(events)) that run bash '\(script)' <event>.",
                        refusal: "isn't valid JSON"
                    ) { try ClaudeHookTransform.install($0, scriptPath: script, family: .remote) }
                    if let change { configs.append(Pending(change: change, needs: [script])) }
                }
                if let change = bridgeChange(.claudeCode, script, bundled.claudeHook, scriptMode,
                                             "Claude Code hook script", reported) {
                    bridges.append(Pending(change: change))
                }
            }

            var kimiScriptNeeded = false
            let kimiScriptPath = kimiScript(home: home.path)
            for family in tomlTools where tools.contains(family.tool) {
                let file = files.first { $0.tool == family.name }
                let path = file?.path ?? "\(home.path)/\(family.dir)/config.toml"
                let (events, leftOut) = acceptedEvents(for: family.tool, kimiEvents)
                if events.isEmpty {
                    // Never an empty list: install with no events removes
                    // the block, and a build that takes none of these has
                    // nothing SwarmBar can register.
                    if seen.first(path, file) {
                        configs.append(Pending(change: PlannedChange(
                            tool: family.tool, path: path, expectSHA256: "", action: .skipped,
                            description: "Skipped \(path): this \(family.tool.label) build accepts none of SwarmBar's hook events")))
                    }
                    continue
                }
                kimiScriptNeeded = true
                var description = "Add \(events.count) hook entries to \(path)"
                if !leftOut.isEmpty {
                    description += ". Left out because this build doesn't accept "
                        + (leftOut.count == 1 ? "it" : "them") + ": " + leftOut.joined(separator: ", ")
                }
                let change = configChange(
                    tool: family.tool, file: file, path: path, seed: "", seen: &seen, description: description,
                    instruction: "Add [[hooks]] entries for \(list(events.map(\.name))) that run '\(kimiScriptPath)' <event>.",
                    refusal: "can't be edited"
                ) { TomlHooksTransform.install($0, scriptPath: kimiScriptPath, family: .remote, events: events) }
                if let change { configs.append(Pending(change: change, needs: [kimiScriptPath])) }
            }
            // One script serves both tools.
            if kimiScriptNeeded, let change = bridgeChange(
                .kimiCode, kimiScriptPath, bundled.kimiHook, scriptMode, "Kimi hook script", reported) {
                bridges.append(Pending(change: change))
            }

            if tools.contains(.openCode) {
                let pluginPath = plugin(home: home.path)
                let spec = pluginSpec(home: home.path)
                // The .jsonc wins when both exist, as it does for the local toggle.
                let opencode = files.filter { $0.tool == "opencode" }
                let file = opencode.first { $0.path.hasSuffix(".jsonc") } ?? opencode.first
                let path = file?.path ?? "\(home.path)/.config/opencode/opencode.json"
                let change = configChange(
                    tool: .openCode, file: file, path: path, seed: "{}\n", seen: &seen,
                    description: "Add the SwarmBar plugin to \(path)",
                    instruction: "Add \"\(spec)\" to its \"plugin\" list.",
                    refusal: "has comments"
                ) { try OpenCodeConfigTransform.install($0, pluginSpec: spec, family: .remote) }
                if let change { configs.append(Pending(change: change, needs: [pluginPath])) }
                if let change = bridgeChange(.openCode, pluginPath, bundled.openCodePlugin, pluginMode,
                                             "OpenCode plugin", reported) {
                    bridges.append(Pending(change: change))
                }
            }
        }

        // Bridge files first, so no config is written before the file it names.
        var paths = Set<String>()
        let uniqueBridges = bridges.filter { paths.insert($0.change.path).inserted }
        let narrow = watchAs == .everyUser && !probe.sudoOK
        let rootLogin = (loginEUID ?? probe.euid) == 0
        return SetupPlan(
            changes: resolve(uniqueBridges + configs),
            installHelper: narrow,
            // A root login has no use for a rule that lets it run its own
            // helper, and needs no sudo to run apply.
            sudoersUser: narrow && !rootLogin ? probe.user : nil,
            watchAs: watchAs,
            helperDestination: helperDestination(homes: homes, watchAs: watchAs),
            system: probe.system,
            useSudo: watchAs == .everyUser && !rootLogin,
            isPartial: narrow && !rootLogin)
    }

    /// The `.remote` uninstall for every config that names a remote bridge,
    /// then the bridge files themselves, each after the configs that named
    /// it. Local entries are never touched.
    /// `loginEUID` as for `plan`.
    static func undoPlan(probe: ProbeResult, watchAs: WatchAs, loginEUID: Int? = nil) throws -> SetupPlan {
        let homes = try watchedHomes(probe, watchAs)
        let owners = fileOwners(probe, homes)
        var configs: [Pending] = []
        var removals: [Pending] = []
        var seen = Seen()

        for home in homes {
            let tools = Set(toolList(probe.tools[home.path]))
            let installed = Set(toolList(probe.installed[home.path]))
            let unknown = Set(toolList(probe.installedUnknown[home.path]))
            let reported = probe.bridges?[home.path]
            let bridges: [(path: String, users: Set<AgentTool>)] = [
                (claudeScript(home: home.path), [.claudeCode]),
                (kimiScript(home: home.path), [.kimiCode, .bearCode]),
                (plugin(home: home.path), [.openCode]),
            ]
            // A bridge file stays while a config that names it needs a hand
            // edit: OpenCode will not start with a plugin entry whose file
            // is gone.
            var keep = Set<String>()
            var namedBy: [String: [String]] = [:]

            for file in probe.configs[home.path] ?? [] {
                if let key = Seen.key(file), owners[key] != home.path { continue }
                guard let tool = ProbeResult.tool(named: file.tool),
                      let bridge = bridges.first(where: { $0.users.contains(tool) })?.path
                else { continue }
                if let text = file.text, file.sha256 != nil {
                    let names: Bool = switch tool {
                    case .claudeCode: ClaudeHookTransform.isInstalled(text, family: .remote)
                    case .openCode: OpenCodeConfigTransform.isInstalled(text, family: .remote)
                    default: TomlHooksTransform.isInstalled(text, family: .remote)
                    }
                    guard names else { continue }
                } else if !installed.contains(tool) && !unknown.contains(tool) {
                    // Unreadable, and nothing says SwarmBar was ever set up here.
                    continue
                }
                let (description, instruction, refusal): (String, String, String) = switch tool {
                case .claudeCode:
                    ("Remove SwarmBar's hook entries from \(file.path)",
                     "Remove the hooks that run \(bridge).", "isn't valid JSON")
                case .openCode:
                    ("Remove the SwarmBar plugin from \(file.path)",
                     "Remove \"file://\(bridge)\" from its \"plugin\" list.", "has comments")
                default:
                    ("Remove SwarmBar's hook entries from \(file.path)",
                     "Remove the [[hooks]] entries that run \(bridge).", "can't be edited")
                }
                let change = configChange(
                    tool: tool, file: file, path: file.path, seed: nil, seen: &seen, description: description,
                    instruction: instruction + " Then delete \(bridge).", refusal: refusal
                ) { text in
                    switch tool {
                    case .claudeCode: try ClaudeHookTransform.uninstall(text, family: .remote)
                    case .openCode: try OpenCodeConfigTransform.uninstall(text, family: .remote)
                    default: TomlHooksTransform.uninstall(text, family: .remote)
                    }
                }
                guard let change else { continue }
                if change.action == .byHand { keep.insert(bridge) }
                namedBy[bridge, default: []].append(change.path)
                configs.append(Pending(change: change))
            }

            let relevant = tools.union(installed).union(unknown)
            for bridge in bridges where !keep.contains(bridge.path) {
                // The probe says which bridge files are there. Without that
                // report, any tool that could have used one counts.
                let there: Bool
                if let reported {
                    there = reported.contains { $0.path == bridge.path && ($0.sha256 != nil || $0.unreadable == true) }
                } else {
                    there = !relevant.isDisjoint(with: bridge.users)
                }
                guard there else { continue }
                removals.append(Pending(
                    change: PlannedChange(
                        tool: bridge.users.count == 1 ? bridge.users.first : .kimiCode, path: bridge.path,
                        expectSHA256: "", action: .remove, description: "Remove \(bridge.path)"),
                    needs: namedBy[bridge.path] ?? []))
            }
        }
        var paths = Set<String>()
        let uniqueRemovals = removals.filter { paths.insert($0.change.path).inserted }
        return SetupPlan(
            changes: resolve(configs + uniqueRemovals), installHelper: false, sudoersUser: nil, watchAs: watchAs,
            helperDestination: helperDestination(homes: homes, watchAs: watchAs), system: probe.system,
            useSudo: watchAs == .everyUser && (loginEUID ?? probe.euid) != 0,
            isPartial: watchAs == .everyUser && !probe.sudoOK && (loginEUID ?? probe.euid) != 0)
    }

    /// The tool a kimi_events key names: its binary's path, or the BearCode
    /// bundle that agent_name recognizes.
    static func kimiTool(forBinary binary: String) -> AgentTool? {
        let name = (binary as NSString).lastPathComponent
        if name == "bearcode" || binary.contains("bearcode-cli/") { return .bearCode }
        if name == "kimi" || name == "kimi-code" { return .kimiCode }
        return nil
    }

    /// Whether every character of a path is one a person can see. A path
    /// holding a newline or another control character would turn the
    /// prompt's shell lines into something else, so it is never sent.
    static func isPrintable(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                false
            default:
                true
            }
        }
    }

    // MARK: Pieces

    /// Every home for every user, or the login user's own. Either way an
    /// empty list is an error, never a plan with nothing in it.
    private static func watchedHomes(_ probe: ProbeResult, _ watchAs: WatchAs) throws -> [RemoteHome] {
        let homes = switch watchAs {
        case .everyUser: probe.homes
        case .loginUser: probe.homes.filter { $0.user == probe.user }
        }
        guard !homes.isEmpty else { throw PlanError.noHome(user: probe.user) }
        return homes
    }

    /// For each (dev, ino) the watched homes share, the home to plan it
    /// from: the first where the probe could read it, since the probe reads
    /// a config only where the home's owner owns it, else the first at all.
    private static func fileOwners(_ probe: ProbeResult, _ homes: [RemoteHome]) -> [String: String] {
        var owners: [String: String] = [:]
        for readable in [true, false] {
            for home in homes {
                for file in probe.configs[home.path] ?? [] where (file.sha256 != nil) == readable {
                    if let key = Seen.key(file), owners[key] == nil { owners[key] = home.path }
                }
            }
        }
        return owners
    }

    private static func helperDestination(homes: [RemoteHome], watchAs: WatchAs) -> String {
        switch watchAs {
        case .everyUser: HelperLaunch.rootHelperPath
        case .loginUser: "\(homes.first?.path ?? "~")/.swarmbar/swarmbar-helper"
        }
    }

    private static func toolList(_ names: [String]?) -> [AgentTool] {
        (names ?? []).compactMap(ProbeResult.tool(named:))
    }

    /// The events every probed build of this tool accepts, in the order
    /// SwarmBar writes them, and the ones left out. Several builds of one
    /// tool get only what all of them accept, since one config can be read
    /// by any of them.
    ///
    /// A key that names no Kimi-family binary is ignored, and a tool with
    /// no recognised key gets the full list. That is safe: the full list
    /// is exactly what the local toggle writes on every Kimi and BearCode
    /// build, and every name in it is in both engines' event enums
    /// (TurnStarted, the one that is not, is deliberately left out of it).
    /// Narrowing only protects a build the probe has actually shown to
    /// reject a name.
    private static func acceptedEvents(
        for tool: AgentTool, _ kimiEvents: [String: [String]]
    ) -> (kept: [(name: String, timeout: Int?)], leftOut: [String]) {
        let builds = kimiEvents.filter { kimiTool(forBinary: $0.key) == tool }.map { Set($0.value) }
        guard let first = builds.first else { return (TomlHooksTransform.events, []) }
        let accepted = builds.dropFirst().reduce(first) { $0.intersection($1) }
        let kept = TomlHooksTransform.events.filter { accepted.contains($0.name) }
        let leftOut = TomlHooksTransform.events.map(\.name).filter { !accepted.contains($0) }
        return (kept, leftOut)
    }

    /// A bridge file's write, against what the probe found there: nothing
    /// when it already holds the bundled bytes, a replacement guarded by
    /// its hash when it differs, a new file only when it is really absent,
    /// and a hand edit when it is there but could not be read.
    private static func bridgeChange(
        _ tool: AgentTool, _ path: String, _ text: String, _ mode: Int, _ name: String,
        _ reported: [ProbeResult.BridgeFile]
    ) -> PlannedChange? {
        let found = reported.first { $0.path == path }
        if found?.unreadable == true {
            return PlannedChange(
                tool: tool, path: path, expectSHA256: "", action: .byHand,
                description: "Edit by hand: SwarmBar couldn't read \(path). Delete it, then set this host up again.")
        }
        guard let sha = found?.sha256 else {
            return PlannedChange(tool: tool, path: path, expectSHA256: absent,
                                 action: .write(newText: text, mode: mode),
                                 description: "Install the \(name) at \(path)")
        }
        if sha == HelperInstaller.sha256(Data(text.utf8)) { return nil }
        return PlannedChange(tool: tool, path: path, expectSHA256: sha, action: .write(newText: text, mode: mode),
                             description: "Update the \(name) at \(path)")
    }

    /// One config's change: the transform's text against the bytes the
    /// probe read, or a hand edit when SwarmBar can't make it. nil when
    /// nothing changes, or the file was already planned under another
    /// name. `seed` is the text of a file that does not exist yet; nil
    /// means a missing file needs nothing.
    private static func configChange(
        tool: AgentTool, file: ProbeResult.ConfigFile?, path: String, seed: String?, seen: inout Seen,
        description: String, instruction: String, refusal: String, transform: (String) throws -> String
    ) -> PlannedChange? {
        guard seen.first(path, file) else { return nil }
        guard let file else {
            guard let seed, let text = try? transform(seed) else { return nil }
            return PlannedChange(tool: tool, path: path, expectSHA256: absent,
                                 action: .write(newText: text, mode: configMode), description: description)
        }
        guard let sha = file.sha256, let current = file.text else {
            return PlannedChange(
                tool: tool, path: path, expectSHA256: file.sha256 ?? "", action: .byHand,
                description: "Edit by hand: SwarmBar couldn't read \(path). \(instruction)")
        }
        let text: String
        do {
            text = try transform(current)
        } catch {
            return PlannedChange(tool: tool, path: path, expectSHA256: sha, action: .byHand,
                                 description: "Edit by hand: \(path) \(refusal). \(instruction)")
        }
        if text == current { return nil }
        return PlannedChange(tool: tool, path: path, expectSHA256: sha,
                             action: .write(newText: text, mode: configMode), description: description)
    }

    /// The final list: a path no one could read safely becomes a hand
    /// edit, then each change's `needs` becomes the indexes of the planned
    /// writes and removals at those paths.
    private static func resolve(_ pending: [Pending]) -> [PlannedChange] {
        var changes = pending.map(\.change)
        for index in changes.indices where !isPrintable(changes[index].path) {
            changes[index].action = .byHand
            changes[index].expectSHA256 = ""
            changes[index].description =
                "Edit by hand: SwarmBar won't write a path with control characters: \(String(reflecting: changes[index].path))"
        }
        for (index, item) in pending.enumerated() {
            // Only earlier changes: the applier goes in order, and a plan
            // is built with what a change waits for ahead of it.
            changes[index].dependsOn = changes.indices.filter { other in
                other < index && changes[other].isSent && item.needs.contains(changes[other].path)
            }
        }
        return changes
    }

    /// "A, B and C".
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// Files already planned, by realpath and by (dev, ino), so a file is
    /// planned once however many names reach it.
    private struct Seen {
        var paths = Set<String>()
        var files = Set<String>()

        static func key(_ file: ProbeResult.ConfigFile) -> String? {
            guard let dev = file.dev, let ino = file.ino else { return nil }
            return "\(dev):\(ino)"
        }

        mutating func first(_ path: String, _ file: ProbeResult.ConfigFile?) -> Bool {
            guard !paths.contains(path) else { return false }
            if let file, let key = Self.key(file) {
                guard files.insert(key).inserted else { return false }
            }
            paths.insert(path)
            return true
        }
    }
}
