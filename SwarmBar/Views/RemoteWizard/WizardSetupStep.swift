import SwiftUI

/// Step 3 for one host: how it is watched, then the three ways to make its
/// changes, as radio cards.
struct WizardSetupStep: View {
    let model: RemoteWizardModel
    let index: Int
    let back: () -> Void
    /// Hosts whose watch-as the user asked to change, so the choice shows
    /// even though a suggestion was taken.
    @State private var changingWatch: Set<String> = []
    /// "Show what it will change", per host and path.
    @State private var expanded: Set<String> = []

    var body: some View {
        if let alias = model.currentAlias, let row = model.rows.first(where: { $0.id == alias }) {
            content(alias, row)
        }
    }

    private func content(_ alias: String, _ row: RemoteWizardModel.Row) -> some View {
        let plan = model.plan(for: alias)
        return WizardScaffold {
            WizardHeading(title: row.displayName,
                          crumbs: "\(index + 1) of \(WizardCopy.hosts(model.setupAliases.count))")
            if model.mode == .undo {
                Text("Takes SwarmBar's hooks back out of this host. The host stays watched.")
                    .wizardMuted()
            }
            if row.isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "Checking \(row.displayName)…")
                        .wizardMuted()
                }
            }
            if model.unfinishedRun {
                unfinished(row)
            }
            // An undo takes out what is there, however the host is watched,
            // so there is nothing to choose.
            if model.mode == .setUp {
                watchSection(alias, row)
            }
            if let warning = model.everyUserWarning(for: alias) {
                WizardNotice(text: warning)
            }
            if let problem = row.problem {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    WizardPill(pill: .cantContinue)
                    Text(verbatim: problem)
                        .swarmFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if case .cantConnect(let problem) = row.assessment?.status {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    WizardPill(pill: .cantConnect)
                    Text(verbatim: problem.message)
                        .swarmFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if plan != nil {
                paths(alias, row)
                handEdits(alias)
            }
        } footer: {
            Button("Back", action: back)
                .disabled(model.isWorking)
            Spacer()
            Button("Skip this host") { model.skipHost() }
                .disabled(model.isWorking)
            primary(alias, plan: plan)
        }
    }

    // MARK: After a run

    /// The last run's outcomes, kept reachable while the fresh plan below
    /// waits for a tap.
    private func unfinished(_ row: RemoteWizardModel.Row) -> some View {
        let key = "\(row.id)\u{0}happened"
        return VStack(alignment: .leading, spacing: 6) {
            WizardNotice(text: "The last run didn't finish everything. The plan below is from a fresh look at the host.")
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
            ) {
                SettingsCard {
                    WizardOutcomeList(changes: model.appliedPlan?.changes ?? [], progress: model.progress,
                                      isWorking: false, hostName: row.displayName)
                        .padding(.vertical, 6)
                }
                .padding(.top, 4)
            } label: {
                Text("Show what happened")
                    .swarmFont(.body)
            }
        }
    }

    // MARK: Watch as

    @ViewBuilder
    private func watchSection(_ alias: String, _ row: RemoteWizardModel.Row) -> some View {
        if let context = model.watchContext(for: alias) {
            let chosen = model.watchAs[alias]
            if row.assessment?.suggestedWatchAs == nil || chosen == nil || changingWatch.contains(alias) {
                if let others = WizardCopy.othersRunAs(context) {
                    Text(verbatim: "\(others) \(WizardCopy.loginLine(context))")
                        .wizardMuted()
                }
                SettingsCard {
                    radio(
                        title: "Just \(context.loginUser)", note: "works now",
                        selected: chosen == .loginUser, enabled: !model.isWorking
                    ) {
                        model.watchAs[alias] = .loginUser
                    } detail: {
                        Text(verbatim: justDetail(context))
                            .wizardMuted()
                    }
                    SettingsDivider()
                    radio(
                        title: "Every user",
                        note: context.sudoOK ? "you have passwordless sudo"
                            : "one command, sudo asks for your password once",
                        selected: chosen == .everyUser, enabled: !model.isWorking
                    ) {
                        model.watchAs[alias] = .everyUser
                    } detail: {
                        if let user = model.plan(for: alias)?.sudoersUser {
                            Text(verbatim: "Lets \(user) run SwarmBar's helper as root, and nothing else:")
                                .wizardMuted()
                            WizardCodeBlock(text: RemoteWizardModel.sudoersLine(user: user),
                                            copyLabel: "Copy sudo rule")
                            Text(verbatim: "Written to \(RemoteWizardModel.sudoersPath) after visudo checks it. "
                                 + "When a SwarmBar update changes the helper, you'll run the command again.")
                                .wizardMuted()
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text(watchingLine(chosen, context))
                        .wizardMuted()
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Button("Change") { changingWatch.insert(alias) }
                        .buttonStyle(.link)
                        .disabled(model.isWorking)
                }
                .swarmFont(.body)
            }
        }
    }

    private func justDetail(_ context: RemoteWizardModel.WatchContext) -> String {
        guard let hidden = WizardCopy.hiddenLine(context) else { return "Watches only your own sessions." }
        return "Watches only your own sessions. The host will say \"\(hidden)\"."
    }

    private func watchingLine(_ chosen: WatchAs?, _ context: RemoteWizardModel.WatchContext) -> AttributedString {
        var who = AttributedString(chosen == .everyUser ? "every user" : "just \(context.loginUser)")
        who.inlinePresentationIntent = .stronglyEmphasized
        var line = AttributedString("Watching ") + who
        if chosen == .everyUser && context.sudoOK {
            line += AttributedString(" (you have passwordless sudo)")
        }
        return line
    }

    // MARK: The three paths

    private func paths(_ alias: String, _ row: RemoteWizardModel.Row) -> some View {
        let selected = model.path[alias]
        let canLet = model.canLetSwarmBarDoIt(alias)
        let command = model.command(for: alias)
        let commandMissing: String? = if case .failure(let why) = command { why.reason } else { nil }
        return SettingsCard {
            radio(
                title: "Let SwarmBar do it", selected: selected == .swarmBar,
                enabled: canLet && !model.isWorking, reason: canLet ? nil : letReason(alias)
            ) {
                model.path[alias] = .swarmBar
            } detail: {
                WizardChangeList(groups: model.changeGroups(for: alias))
            }
            SettingsDivider()
            radio(
                title: "Paste into an agent on \(row.displayName)", selected: selected == .paste,
                enabled: !model.isWorking
            ) {
                model.path[alias] = .paste
            } detail: {
                pasteDetail(alias)
            }
            SettingsDivider()
            radio(
                title: "Run a command yourself", selected: selected == .command,
                enabled: commandMissing == nil && !model.isWorking, reason: commandMissing
            ) {
                model.path[alias] = .command
            } detail: {
                commandDetail(alias, row, command)
            }
        }
    }

    /// Why SwarmBar can't make the changes itself. Watching every user
    /// without passwordless sudo is the case worth explaining; anything
    /// else already shows as the host's own problem above.
    private func letReason(_ alias: String) -> String? {
        guard model.watchAs[alias] == .everyUser, model.watchContext(for: alias)?.sudoOK == false else { return nil }
        return "It would need your password, and SwarmBar never handles one."
    }

    @ViewBuilder private func pasteDetail(_ alias: String) -> some View {
        Text("Give this to any agent running there. It has the exact contents, so the agent doesn't improvise.")
            .wizardMuted()
        if let prompt = model.prompt(for: alias) {
            WizardCodeBlock(text: prompt.text, copyLabel: "Copy prompt", maxHeight: 150)
        }
        let omitted = model.pasteOmissions(for: alias)
        if !omitted.isEmpty {
            let command = if case .success = model.command(for: alias) { true } else { false }
            WizardNotice(text: WizardCopy.omissionsLead(letSwarmBar: model.canLetSwarmBarDoIt(alias), command: command)
                + "\n" + omitted.map { "• \($0)" }.joined(separator: "\n"))
        }
        disclosure(alias, "paste", model.changeGroups(for: alias))
    }

    @ViewBuilder private func commandDetail(
        _ alias: String, _ row: RemoteWizardModel.Row, _ command: Result<String, SetupCommand.Unavailable>?
    ) -> some View {
        if case .success(let text) = command {
            Text(verbatim: "Run it in a terminal on \(row.displayName). It downloads SwarmBar "
                 + "\(model.helperVersion)'s helper, checks its checksum, and makes the changes below.")
                .wizardMuted()
            WizardCodeBlock(text: text, copyLabel: "Copy command")
        }
        disclosure(alias, "command", model.changeGroups(for: alias, forCommand: true))
    }

    private func disclosure(_ alias: String, _ path: String, _ groups: [RemoteWizardModel.ChangeGroup]) -> some View {
        let key = "\(alias)\u{0}\(path)"
        return DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(key) },
            set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
        ) {
            WizardChangeList(groups: groups)
                .padding(.top, 4)
        } label: {
            Text("Show what it will change")
                .swarmFont(.body)
        }
    }

    // MARK: Hand edits

    @ViewBuilder private func handEdits(_ alias: String) -> some View {
        let edits = model.handEdits(for: alias)
        if !edits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroupLabel("Edit by hand")
                SettingsCard {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(edits.enumerated()), id: \.offset) { _, edit in
                            Text(verbatim: Self.withoutPrefix(edit))
                                .swarmFont(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The heading already says "Edit by hand".
    private static func withoutPrefix(_ edit: String) -> String {
        let prefix = "Edit by hand: "
        return edit.hasPrefix(prefix) ? String(edit.dropFirst(prefix.count)) : edit
    }

    // MARK: Footer

    @ViewBuilder private func primary(_ alias: String, plan: SetupPlan?) -> some View {
        if plan == nil && model.watchAs[alias] == nil {
            // Nothing to make until the user picks, so no button says so.
            Text("Pick how SwarmBar should watch this host.")
                .wizardMuted()
        } else if plan == nil {
            // Something stopped the plan, which a fresh look may clear.
            Button("Check again") { Task { await model.confirmPastedOrRan() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
        } else {
            switch model.path[alias] ?? .swarmBar {
            case .swarmBar:
                // No Return default here: the step before has one too, so
                // two presses of Return would write to a host.
                Button("Make these changes") { Task { await model.makeChanges() } }
                    .disabled(!model.canLetSwarmBarDoIt(alias) || model.isBusy)
            case .paste:
                Button("I've pasted it, check now") { Task { await model.confirmPastedOrRan() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            case .command:
                Button("I've run it, check now") { Task { await model.confirmPastedOrRan() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            }
        }
    }

    // MARK: Radio cards

    /// One option: a radio and its title, with its detail only while it is
    /// the one chosen. `reason` says why an option can't be chosen.
    private func radio<Detail: View>(
        title: String, note: String? = nil, selected: Bool, enabled: Bool, reason: String? = nil,
        select: @escaping () -> Void, @ViewBuilder detail: () -> Detail
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    Text(verbatim: title)
                        .swarmFont(.rowTitle)
                    if let note {
                        Text(verbatim: "· \(note)")
                            .swarmFont(.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let reason {
                Text(verbatim: reason)
                    .wizardMuted()
                    .padding(.leading, 24)
            }
            if selected {
                VStack(alignment: .leading, spacing: 8) { detail() }
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .opacity(enabled || selected ? 1 : 0.6)
    }
}
