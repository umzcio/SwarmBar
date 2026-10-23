import Foundation

/// Makes a setup plan's changes over a live helper channel, one request per
/// change, in order. The sudo rule and root's helper are never made here:
/// those need a password, and only the setup command a person runs can
/// carry them.
@MainActor
final class SetupApplier {
    enum StepOutcome: Equatable, Sendable {
        case done
        /// The file was not what the plan was made against: its hash
        /// differs, or a file that had to be new is already there. Nothing
        /// was written.
        case changed
        case failed(String)
        /// Never sent: a person has to make it.
        case byHand
        /// Never sent: nothing is needed, as the change's description says.
        case skipped
    }

    static let dependencyFailed = "skipped because a change it depends on did not apply"

    private let connection: SSHChannel

    init(connection: SSHChannel) {
        self.connection = connection
    }

    /// Reports every change's outcome by its index in `plan.changes`. A
    /// change that comes back changed or failed stops only itself and the
    /// changes that depend on it: each file is guarded by its own hash, so
    /// the rest are still safe to make, but a config is never written to
    /// name a bridge file that did not go in, and a bridge file is never
    /// removed while a config still names it.
    func apply(_ plan: SetupPlan, progress: @MainActor (Int, StepOutcome) -> Void) async {
        // The wizard can reach a host before any monitor has installed the
        // helper there, and an older helper may not know write_file.
        let (alias, watchAs): (String, WatchAs) = switch connection.launch {
        case .ssh(let alias, let watchAs): (alias, watchAs)
        case .local: ("local", .loginUser)
        }
        switch await HelperInstaller.ensureInstalled(alias: alias, watchAs: watchAs, channel: connection) {
        case .current, .installed:
            break
        case .failed(let message), .needsSetup(let message):
            for (index, change) in plan.changes.enumerated() {
                progress(index, Self.unsent(change) ?? .failed(message))
            }
            return
        }
        var outcomes: [StepOutcome] = []
        for change in plan.changes {
            let outcome: StepOutcome
            if let unsent = Self.unsent(change) {
                outcome = unsent
            } else if change.dependsOn.contains(where: { $0 >= outcomes.count || outcomes[$0] != .done }) {
                outcome = .failed(Self.dependencyFailed)
            } else {
                outcome = await step(change)
            }
            outcomes.append(outcome)
            progress(outcomes.count - 1, outcome)
        }
    }

    /// What a change that is never sent comes to, or nil for one that is.
    private static func unsent(_ change: PlannedChange) -> StepOutcome? {
        switch change.action {
        case .write, .remove: nil
        case .byHand: .byHand
        case .skipped: .skipped
        }
    }

    private func step(_ change: PlannedChange) async -> StepOutcome {
        var arguments: [String: JSONValue] = ["path": .string(change.path)]
        let command: String
        switch change.action {
        case .write(let text, let mode):
            command = "write_file"
            arguments["content_b64"] = .string(Data(text.utf8).base64EncodedString())
            arguments["expect_sha256"] = .string(change.expectSHA256)
            arguments["mode"] = .int(mode)
        case .remove:
            command = "remove_file"
        case .byHand:
            return .byHand
        case .skipped:
            return .skipped
        }
        do {
            return Self.outcome(of: try await connection.request(command, arguments))
        } catch {
            return .failed("\(error)")
        }
    }

    private struct Reply: Decodable {
        let ok: Bool
        let error: String?
    }

    nonisolated static func outcome(of line: Data) -> StepOutcome {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else {
            return .failed("the helper's answer couldn't be read")
        }
        if reply.ok { return .done }
        if reply.error == "changed" { return .changed }
        return .failed(reply.error ?? "the helper refused")
    }
}
