import Foundation
import Synchronization
import Testing
@testable import SwarmBar

/// Synthetic probe results only: every host, user and path here is made up.
@Suite struct HostAssessmentTests {
    private static let appHelper = "1111111111111111111111111111111111111111111111111111111111111111"

    private static func process(_ comm: String, user: String = "u", pid: Int = 100) -> RemoteProcessRecord {
        RemoteProcessRecord(
            pid: pid, ppid: 1, user: user, comm: comm, args: comm, cwd: "/home/u/work", tty: "pts/1",
            pane: nil, open: [], openFailed: false, screen: nil)
    }

    private static func probe(
        user: String = "u", sudo: Bool = false, homes: [String] = ["/home/u"],
        processes: [RemoteProcessRecord] = [], tools: [String] = [], installed: [String] = [],
        unknown: [String] = [], helper: [ProbeResult.HelperFile] = [], processesFailed: Bool = false,
        selfSHA256: String? = nil
    ) -> ProbeResult {
        ProbeResult(
            alias: "devbox", protocolVersion: 3, system: "Linux", python: "3.12.3", hostname: "devbox",
            user: user, euid: user == "root" ? 0 : 1000, sudoOK: sudo,
            homes: homes.map { RemoteHome(path: $0, user: $0 == "/root" ? "root" : "u") },
            processes: processes, processesFailed: processesFailed,
            tools: Dictionary(uniqueKeysWithValues: homes.map { ($0, tools) }),
            installed: Dictionary(uniqueKeysWithValues: homes.map { ($0, installed) }),
            installedUnknown: Dictionary(uniqueKeysWithValues: homes.map { ($0, unknown) }),
            helper: helper, selfSHA256: selfSHA256)
    }

    private static func assess(
        user: ProbeResult?, root: ProbeResult? = nil, failure: HostProblem? = nil, watchAs: WatchAs? = nil
    ) -> HostAssessment {
        HostAssessment.assess(user: user, root: root, failure: failure, watchAs: watchAs, helperSHA256: appHelper)
    }

    @Test func sudoHostSuggestsEveryUser() {
        let user = Self.probe(sudo: true, processes: [Self.process("claude", user: "root")])
        let root = Self.probe(
            user: "root", sudo: true, homes: ["/root", "/home/u"],
            processes: [Self.process("claude", user: "root")], tools: ["claude"], installed: ["claude"])
        let ready = Self.assess(user: user, root: root)
        #expect(ready.suggestedWatchAs == .everyUser)
        #expect(ready.status == .ready)
        #expect(ready.hiddenSessions == 0)

        // Watching every user with sudo, the root view is the one judged.
        let missing = Self.probe(user: "root", sudo: true, homes: ["/root"], tools: ["claude"])
        #expect(Self.assess(user: user, root: missing).status
            == .needsSetup(["Claude Code approvals not set up"]))
    }

    @Test func rootAgentsWithoutSudoNeedAPick() {
        let user = Self.probe(processes: [Self.process("codex", user: "root")])
        let result = Self.assess(user: user)
        #expect(result.suggestedWatchAs == nil)
        #expect(result.status == .needsSetup([HostAssessment.pickReason]))
        #expect(HostAssessment.pickReason
            == "Agents here run as root. Pick how SwarmBar should watch this host.")
    }

    @Test func ownAgentsWithoutSudoAreReadyAsLoginUser() {
        let user = Self.probe(processes: [Self.process("claude")], tools: ["claude"], installed: ["claude"])
        let result = Self.assess(user: user)
        #expect(result.suggestedWatchAs == .loginUser)
        #expect(result.status == .ready)
    }

    @Test func missingClaudeHooksNeedSetup() {
        let user = Self.probe(processes: [Self.process("claude")], tools: ["claude", "opencode", "kimi"],
                              installed: ["opencode"])
        #expect(Self.assess(user: user).status
            == .needsSetup(["Claude Code approvals not set up", "Kimi Code approvals not set up"]))
    }

    @Test func codexOnlyHostNeedsNothingInstalled() {
        let user = Self.probe(processes: [Self.process("codex")], tools: ["codex", "grok", "antigravity"])
        #expect(Self.assess(user: user).status == .ready)
    }

    @Test func staleRootHelperUnderNarrowRuleNeedsSetup() {
        let path = HelperLaunch.rootHelperPath
        let stale = Self.probe(helper: [.init(path: path, sha256: String(repeating: "2", count: 64))])
        #expect(Self.assess(user: stale, watchAs: .everyUser).status
            == .needsSetup([HostAssessment.narrowProbeFailedReason, HelperInstaller.updateNeedsSetupMessage]))

        // With the narrow rule's root view: ready when root's helper is this
        // build's, stale when it says otherwise.
        let unreadable = Self.probe(helper: [.init(path: path, sha256: nil)])
        let rootView = Self.probe(user: "root", homes: ["/root", "/home/u"], selfSHA256: Self.appHelper)
        #expect(Self.assess(user: unreadable, root: rootView, watchAs: .everyUser).status == .ready)
        let oldRoot = Self.probe(user: "root", homes: ["/root"], selfSHA256: String(repeating: "3", count: 64))
        #expect(Self.assess(user: unreadable, root: oldRoot, watchAs: .everyUser).status
            == .needsSetup([HelperInstaller.updateNeedsSetupMessage]))
        // Root's own 700 file cannot be read without sudo. Unknown is not
        // stale, but without a root view the host is still never Ready.
        #expect(Self.assess(user: unreadable, watchAs: .everyUser).status
            == .needsSetup([HostAssessment.narrowProbeFailedReason]))
        #expect(HostAssessment.narrowProbeFailedReason
            == "SwarmBar can't look at the other users' sessions yet. Run the setup command.")

        let absent = Self.probe()
        #expect(Self.assess(user: absent, watchAs: .everyUser).status
            == .needsSetup([HostAssessment.sudoRuleReason]))

        // The helper in the login user's home says nothing about root's.
        let wrongFile = Self.probe(helper: [.init(path: "/home/u/.swarmbar/swarmbar-helper", sha256: Self.appHelper)])
        #expect(Self.assess(user: wrongFile, watchAs: .everyUser).status
            == .needsSetup([HostAssessment.sudoRuleReason]))
    }

    @Test func narrowRuleRootViewIsJudgedForEveryHome() {
        let user = Self.probe(processes: [Self.process("claude", user: "root")],
                              helper: [.init(path: HelperLaunch.rootHelperPath, sha256: nil)])
        let root = Self.probe(user: "root", homes: ["/root", "/home/u"], processes: user.processes,
                              tools: ["claude"], selfSHA256: Self.appHelper)
        let result = Self.assess(user: user, root: root, watchAs: .everyUser)
        #expect(result.status == .needsSetup(["Claude Code approvals not set up"]))
        #expect(result.summary == "1 Claude Code")
    }

    @Test func processesFailedWithoutSudoLeavesThePickOpen() {
        let user = Self.probe(tools: ["codex"], processesFailed: true)
        let result = Self.assess(user: user)
        #expect(result.suggestedWatchAs == nil)
        #expect(result.hiddenSessions == nil)
        #expect(result.status == .needsSetup([HostAssessment.processesFailedReason]))
        #expect(HostAssessment.processesFailedReason
            == "SwarmBar couldn't list the processes on this host. Check again.")
        // Picked, it is still not Ready: nobody knows what runs there.
        let picked = Self.assess(user: user, watchAs: .loginUser)
        #expect(picked.status == .needsSetup([HostAssessment.processesFailedReason]))
        #expect(picked.hiddenSessions == nil)
        // A host that cannot connect says that instead.
        #expect(Self.assess(user: nil, failure: .timedOut).status == .cantConnect(.timedOut))
    }

    @Test func sudoWithoutARootViewIsNeverJudgedOnTheUserView() {
        let user = Self.probe(sudo: true, tools: ["claude"], installed: ["claude"])
        let result = Self.assess(user: user, root: nil)
        #expect(result.suggestedWatchAs == .everyUser)
        #expect(result.status == .needsSetup([HostAssessment.rootViewMissingReason]))
    }

    @Test func rootFailureMattersOnlyWhenWatchingEveryUser() {
        let user = Self.probe(sudo: true, processes: [Self.process("claude")], tools: ["claude"],
                              installed: ["claude"])
        let failure = HostProblem.other("sudo: a password is required")
        #expect(Self.assess(user: user, failure: failure).status == .cantConnect(failure))
        #expect(Self.assess(user: user, failure: failure, watchAs: .everyUser).status == .cantConnect(failure))
        let mine = Self.assess(user: user, failure: failure, watchAs: .loginUser)
        #expect(mine.status == .ready)
        #expect(mine.hiddenSessions == 0)
        #expect(mine.summary == "1 Claude Code")
    }

    @Test func unreadableConfigIsNeverReady() {
        let user = Self.probe(processes: [Self.process("kimi")], tools: ["kimi"], unknown: ["kimi"])
        #expect(Self.assess(user: user).status
            == .needsSetup(["SwarmBar couldn't read the Kimi Code config on this host. Check again."]))
        // A home where it is plainly missing says so instead.
        let mixed = Self.probe(homes: ["/home/u", "/home/v"], processes: [Self.process("kimi")],
                               tools: ["kimi"])
        #expect(Self.assess(user: mixed).status == .needsSetup(["Kimi Code approvals not set up"]))
    }

    @Test func pickedLoginUserNeedsNoPick() {
        let user = Self.probe(processes: [Self.process("codex", user: "root")])
        let result = Self.assess(user: user, watchAs: .loginUser)
        #expect(result.status == .ready)
        #expect(result.suggestedWatchAs == nil)
    }

    @Test func hiddenSessionsCounted() {
        let user = Self.probe(processes: [
            Self.process("codex", user: "root", pid: 1), Self.process("codex", user: "root", pid: 2),
            Self.process("claude", pid: 3),
        ], tools: ["claude"], installed: ["claude"])
        #expect(Self.assess(user: user, watchAs: .loginUser).hiddenSessions == 2)
        #expect(Self.assess(user: user, watchAs: nil).hiddenSessions == 0)

        let sudo = Self.probe(sudo: true, processes: user.processes)
        let root = Self.probe(user: "root", sudo: true, processes: user.processes)
        #expect(Self.assess(user: sudo, root: root, watchAs: .everyUser).hiddenSessions == 0)
    }

    @Test func summaryOrdersByTool() {
        let names = ["grok", "claude", "kimi-code", "claude", "kimi", "agy", "bearcode", "claude", "opencode"]
        let user = Self.probe(processes: names.enumerated().map { Self.process($1, pid: $0) })
        #expect(Self.assess(user: user).summary
            == "3 Claude Code, 2 Kimi Code, 1 BearCode, 1 OpenCode, 1 Grok Build, 1 Antigravity")
        #expect(Self.assess(user: Self.probe()).summary == "No agents running")
        #expect(Self.assess(user: Self.probe(processesFailed: true)).summary == HostAssessment.processesUnknown)
    }

    @Test func failureGivesCantConnect() {
        let result = Self.assess(user: nil, failure: .timedOut)
        #expect(result.status == .cantConnect(.timedOut))
        #expect(result.suggestedWatchAs == nil)
        #expect(Self.assess(user: nil).status == .cantConnect(.other("No answer from the host")))
        #expect(result.hiddenSessions == nil)
    }

    @Test func classifiesSSHFailures() {
        func classify(_ stderr: String, _ status: Int32 = 255) -> HostProblem {
            SSHFailure.classify(stderr: stderr, exitStatus: status)
        }
        #expect(classify("u@devbox: Permission denied (publickey,password).\r\n") == .needsPassword)
        #expect(classify("u@devbox: Permission denied (publickey).\r\n") == .keyRejected)
        #expect(classify("""
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            Host key verification failed.
            """) == .hostKeyChanged)
        #expect(classify("""
            No ED25519 host key is known for devbox and you have requested strict checking.
            Host key verification failed.
            """) == .other("Host key isn't known yet. Connect once in a terminal to check it."))
        #expect(classify("u@devbox: Permission denied (publickey,keyboard-interactive).\r\n") == .needsPassword)
        #expect(classify("ssh: connect to host devbox port 22: Operation timed out\r\n") == .timedOut)
        #expect(classify("Connection timed out during banner exchange\r\n") == .timedOut)
        #expect(classify("ssh: Could not resolve hostname devbox: nodename nor servname provided, or not known\r\n")
            == .unresolvable)
        #expect(classify("bash: line 1: python3: command not found\n", 127) == .noPython)
        #expect(classify("", 127) == .noPython)
        #expect(classify("  File \"<stdin>\", line 40\nSyntaxError: invalid syntax\n", 1) == .pythonTooOld(nil))
        #expect(classify("u@devbox: Permission denied (publickey,gssapi-keyex,gssapi-with-mic).\r\n")
            == .keyRejected)
        #expect(classify("""
            Warning: Permanently added 'devbox' (ED25519) to the list of known hosts.
            kex_exchange_identification: Connection closed by remote host
            """) == .other("kex_exchange_identification: Connection closed by remote host"))
        #expect(classify("""
            Traceback (most recent call last):
              File "<stdin>", line 12, in <module>
            ModuleNotFoundError: No module named 'fcntl'
            """, 1) == .other("ModuleNotFoundError: No module named 'fcntl'"))
        #expect(classify("kex_exchange_identification: read: Connection reset by peer\r\n")
            == .other("kex_exchange_identification: read: Connection reset by peer"))
        #expect(classify("", 255) == .other("ssh exited 255"))
    }

    @Test func problemMessagesAreTheMockupsCopy() {
        #expect(HostProblem.needsPassword.message == "Asks for a password. Add your key with ssh-copy-id.")
        #expect(HostProblem.keyRejected.message == "Your key isn't accepted")
        #expect(HostProblem.hostKeyChanged.message == "Host key changed. Check it before connecting.")
        #expect(HostProblem.timedOut.message == "Timed out after 10 s")
        #expect(HostProblem.unresolvable.message == "Name doesn't resolve")
        #expect(HostProblem.noPython.message == "python3 isn't installed")
        #expect(HostProblem.pythonTooOld(nil).message == "python3 is too old (needs 3.9)")
        #expect(HostProblem.pythonTooOld("3.6.9").message == "python3 is too old (needs 3.9), found 3.6.9")
        #expect(HostProblem.other("odd").message == "odd")
    }

    @Test func decodesTheHelpersProbe() throws {
        let line = Self.probeJSON(sudo: true)
        let result = try JSONDecoder().decode(ProbeResult.self, from: Data(line.utf8))
        #expect(result.sudoOK)
        #expect(result.python == "3.12.3")
        #expect(result.homes == [RemoteHome(path: "/home/u", user: "u")])
        #expect(result.processes.map(\.comm) == ["claude"])
        #expect(result.processes.first?.screen == nil)
        #expect(result.tools["/home/u"] == ["claude"])
        #expect(result.configs["/home/u"]?.first?.text == nil)
        #expect(result.configs["/home/u"]?.last == ProbeResult.ConfigFile(
            tool: "kimi", path: "/home/u/.kimi-code/config.toml", sha256: nil, text: nil))
        #expect(result.selfSHA256 == nil)
        #expect(result.helper == [ProbeResult.HelperFile(path: "/usr/local/lib/swarmbar-helper", sha256: nil)])
        #expect(result.alias == "")
    }

    // MARK: ProbeRunner

    static func probeJSON(sudo: Bool, python: String = "3.12.3", rootHelper: Bool = true) -> String {
        """
        {"ok": true, "protocol": 3, "system": "Linux", "python": "\(python)", "hostname": "devbox",
         "user": "u", "euid": 1000, "sudo_ok": \(sudo),
         "homes": [{"path": "/home/u", "user": "u"}],
         "processes": [{"pid": 7, "ppid": 1, "user": "u", "tty": "pts/1", "comm": "claude",
                        "args": "claude", "cwd": "/home/u/work", "pane": null, "open": []}],
         "processes_failed": false,
         "tools": {"/home/u": ["claude"]}, "installed": {"/home/u": []},
         "installed_unknown": {"/home/u": []},
         "configs": {"/home/u": [{"tool": "claude", "path": "/home/u/.claude/settings.json",
                                  "sha256": "abc", "text": null},
                                 {"tool": "kimi", "path": "/home/u/.kimi-code/config.toml",
                                  "sha256": null, "text": null}]},
         "helper": \(rootHelper ? #"[{"path": "/usr/local/lib/swarmbar-helper", "sha256": null}]"# : "[]"),
         "warnings": []}
        """.replacingOccurrences(of: "\n", with: " ") + "\n"
    }

    /// Records every ssh it is asked to run and answers from a script.
    final class FakeSSH: Sendable {
        struct Call: Sendable, Equatable { let arguments: [String]; let stdin: Data; let deadline: TimeInterval }
        private let state = Mutex<(calls: [Call], running: Int, peak: Int)>(([], 0, 0))
        let answer: @Sendable ([String]) -> ProbeRunner.RunResult
        let delay: Duration

        init(delay: Duration = .zero, answer: @escaping @Sendable ([String]) -> ProbeRunner.RunResult) {
            self.answer = answer
            self.delay = delay
        }

        var calls: [Call] { state.withLock { $0.calls } }
        var peak: Int { state.withLock { $0.peak } }

        var runner: ProbeRunner.Runner {
            { [self] arguments, stdin, deadline in
                state.withLock {
                    $0.calls.append(Call(arguments: arguments, stdin: stdin, deadline: deadline))
                    $0.running += 1
                    $0.peak = max($0.peak, $0.running)
                }
                if delay > .zero { try? await Task.sleep(for: delay) }
                state.withLock { $0.running -= 1 }
                return answer(arguments)
            }
        }
    }

    private static func ok(_ line: String) -> ProbeRunner.RunResult {
        ProbeRunner.RunResult(status: 0, stdout: Data(line.utf8), stderr: Data(), timedOut: false)
    }

    @Test func runnerArgumentsEndOptionsBeforeTheAlias() {
        #expect(ProbeRunner.userArguments(alias: "devbox")
            == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "devbox", "python3", "-B", "-", "probe"])
        #expect(ProbeRunner.rootArguments(alias: "devbox")
            == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "devbox",
                "sudo", "-n", "python3", "-B", "-", "probe"])
        #expect(ProbeRunner.narrowRootArguments(alias: "devbox")
            == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "devbox",
                "sudo", "-n", "/usr/local/lib/swarmbar-helper", "probe"])
    }

    @Test func rootProbeRunsOnlyWithSudo() async {
        let source = Data("# helper source\n".utf8)
        let noSudo = FakeSSH { _ in Self.ok(Self.probeJSON(sudo: false, rootHelper: false)) }
        let plain = await ProbeRunner(helperSource: source, runner: noSudo.runner).probe(alias: "alpha")
        #expect(noSudo.calls.map(\.arguments) == [ProbeRunner.userArguments(alias: "alpha")])
        #expect(noSudo.calls.first?.stdin == source)
        #expect(noSudo.calls.first?.deadline == 20)
        #expect(plain.user?.alias == "alpha")
        #expect(plain.root == nil)
        #expect(plain.failure == nil)

        let sudo = FakeSSH { _ in Self.ok(Self.probeJSON(sudo: true)) }
        let both = await ProbeRunner(helperSource: source, runner: sudo.runner).probe(alias: "beta")
        #expect(sudo.calls.map(\.arguments)
            == [ProbeRunner.userArguments(alias: "beta"), ProbeRunner.rootArguments(alias: "beta")])
        #expect(sudo.calls.last?.stdin == source)
        #expect(both.root?.alias == "beta")
        #expect(both.failure == nil)
    }

    @Test func narrowRuleRootViewUsesTheInstalledHelper() async {
        let fake = FakeSSH { arguments in
            arguments.contains("sudo")
                ? Self.ok(Self.probeJSON(sudo: true).replacingOccurrences(of: "\"user\": \"u\", \"euid\": 1000",
                                                                         with: "\"user\": \"root\", \"euid\": 0"))
                : Self.ok(Self.probeJSON(sudo: false))
        }
        let result = await ProbeRunner(helperSource: Data("# helper\n".utf8), runner: fake.runner)
            .probe(alias: "alpha")
        #expect(fake.calls.map(\.arguments)
            == [ProbeRunner.userArguments(alias: "alpha"), ProbeRunner.narrowRootArguments(alias: "alpha")])
        #expect(fake.calls.last?.stdin == Data())
        #expect(result.root?.user == "root")
        #expect(result.failure == nil)

        // A stale helper that does not know the probe, or a rule that is
        // gone, is no root view, never a failure to connect.
        for reply in [Self.ok("not json\n"),
                      Self.ok("{\"ok\": false, \"error\": \"unknown command\"}\n"),
                      ProbeRunner.RunResult(status: 1, stdout: Data(),
                                            stderr: Data("sudo: a password is required\n".utf8), timedOut: false)] {
            let stale = FakeSSH { arguments in arguments.contains("sudo") ? reply : Self.ok(Self.probeJSON(sudo: false)) }
            let outcome = await ProbeRunner(helperSource: Data(), runner: stale.runner).probe(alias: "alpha")
            #expect(outcome.user != nil)
            #expect(outcome.root == nil)
            #expect(outcome.failure == nil)
        }
    }

    @Test func unsafeAliasIsRefusedWithoutRunningSSH() async {
        let fake = FakeSSH { _ in Self.ok(Self.probeJSON(sudo: false)) }
        let result = await ProbeRunner(helperSource: Data(), runner: fake.runner).probe(alias: "-oProxyCommand=x")
        #expect(result.failure == .other("unsafe alias"))
        #expect(result.user == nil)
        #expect(fake.calls.isEmpty)
    }

    @Test func runnerFailuresAreClassified() async {
        let timedOut = FakeSSH { _ in
            ProbeRunner.RunResult(status: 15, stdout: Data(), stderr: Data(), timedOut: true)
        }
        #expect(await ProbeRunner(helperSource: Data(), runner: timedOut.runner).probe(alias: "alpha").failure
            == .timedOut)

        let refused = FakeSSH { _ in
            ProbeRunner.RunResult(status: 255, stdout: Data(),
                                  stderr: Data("u@alpha: Permission denied (publickey).\r\n".utf8), timedOut: false)
        }
        #expect(await ProbeRunner(helperSource: Data(), runner: refused.runner).probe(alias: "alpha").failure
            == .keyRejected)

        let old = FakeSSH { _ in Self.ok(Self.probeJSON(sudo: true, python: "3.6.9")) }
        let tooOld = await ProbeRunner(helperSource: Data(), runner: old.runner).probe(alias: "alpha")
        #expect(tooOld.failure == .pythonTooOld("3.6.9"))
        #expect(old.calls.count == 1)

        let sudoFails = FakeSSH { arguments in
            arguments.contains("sudo")
                ? ProbeRunner.RunResult(status: 1, stdout: Data(),
                                        stderr: Data("sudo: a password is required\n".utf8), timedOut: false)
                : Self.ok(Self.probeJSON(sudo: true))
        }
        let rootless = await ProbeRunner(helperSource: Data(), runner: sudoFails.runner).probe(alias: "alpha")
        #expect(rootless.user != nil)
        #expect(rootless.root == nil)
        #expect(rootless.failure == .other("sudo: a password is required"))

        let ancient = FakeSSH { _ in
            Self.ok("{\"ok\": false, \"protocol\": 3, \"python\": \"3.6.9\", \"error\": \"probe failed: x\"}\n")
        }
        #expect(await ProbeRunner(helperSource: Data(), runner: ancient.runner).probe(alias: "alpha").failure
            == .pythonTooOld("3.6.9"))

        let broken = FakeSSH { _ in Self.ok("{\"ok\": false, \"protocol\": 3, \"error\": \"probe failed: boom\"}\n") }
        #expect(await ProbeRunner(helperSource: Data(), runner: broken.runner).probe(alias: "alpha").failure
            == .other("probe failed: boom"))
    }

    @Test func processRunnerFeedsStdinAndKeepsItsDeadline() async {
        let big = Data(repeating: UInt8(ascii: "x"), count: 300_000)
        let counted = await ProbeRunner.runProcess(
            executable: "/bin/sh", arguments: ["-c", "wc -c"], stdin: big, deadline: 10)
        #expect(String(decoding: counted.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            == "300000")
        #expect(counted.status == 0)
        #expect(!counted.timedOut)

        let started = Date.now
        let slow = await ProbeRunner.runProcess(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"], stdin: Data(), deadline: 0.3)
        #expect(slow.timedOut)
        #expect(Date.now.timeIntervalSince(started) < 5)

        // A grandchild still holding stdout must not hold the probe open.
        let lingering = Date.now
        let forked = await ProbeRunner.runProcess(
            executable: "/bin/sh", arguments: ["-c", "sleep 3 & echo answered"], stdin: Data(), deadline: 10)
        #expect(String(decoding: forked.stdout, as: UTF8.self) == "answered\n")
        #expect(Date.now.timeIntervalSince(lingering) < 5)
    }

    @Test func probeAllRunsAtMostSixAtOnce() async {
        let fake = FakeSSH(delay: .milliseconds(40)) { _ in Self.ok(Self.probeJSON(sudo: false)) }
        let runner = ProbeRunner(helperSource: Data(), runner: fake.runner)
        let aliases = (1...15).map { "host\($0)" }
        var seen: [String] = []
        for await (alias, result) in runner.probeAll(aliases) {
            #expect(result.user?.alias == alias)
            seen.append(alias)
        }
        #expect(Set(seen) == Set(aliases))
        #expect(seen.count == aliases.count)
        #expect(fake.peak <= ProbeRunner.maxConcurrent)
        #expect(fake.peak > 1)
    }
}
