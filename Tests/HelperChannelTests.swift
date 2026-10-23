import Foundation
import Testing
@testable import SwarmBar

private let pythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// A fresh, empty home per test, so the helper reads nothing real.
private func freshHome() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("swarmbar-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

/// The bundled helper, run locally. The test host is the app, so
/// `Bundle.main` is the app bundle the real install step reads from.
private func localHelper() throws -> HelperLaunch {
    let script = try #require(Bundle.main.url(forResource: "swarmbar-helper", withExtension: "py"))
    return .local(python: "/usr/bin/python3", script: script.path, homes: [try freshHome()])
}

/// A stand-in helper whose timing the test controls. It answers every
/// request after sleeping for the request's `delay`, and pushes one event
/// first when asked to `emit`. It never answers `hang`, exits on `die`, and
/// answers `snapshot` with `ok: false`.
private func scriptedHelper() throws -> HelperLaunch {
    let source = """
    import json, sys, time
    for line in sys.stdin:
        request = json.loads(line)
        command = request.get("cmd")
        if command == "hang":
            continue
        if command == "die":
            sys.stderr.write("an earlier complaint\\nsynthetic last words\\n")
            sys.stderr.flush()
            sys.exit(3)
        if command == "snapshot":
            print(json.dumps({"ok": False, "error": "synthetic", "id": request["id"]}), flush=True)
            continue
        if command == "emit":
            print(json.dumps({"event": "hook", "detail": "synthetic"}), flush=True)
        time.sleep(request.get("delay", 0))
        print(json.dumps({"ok": True, "id": request["id"], "cmd": request.get("cmd")}), flush=True)
    """
    let path = try freshHome() + "/scripted-helper.py"
    try source.write(toFile: path, atomically: true, encoding: .utf8)
    return .local(python: "/usr/bin/python3", script: path, homes: [])
}

private struct PingReply: Decodable {
    let ok: Bool
    let id: Int
    let `protocol`: Int
    let sha256: String
}

@Suite("Helper channel")
struct HelperChannelTests {
    @Test("watching every user runs the root helper through sudo")
    func everyUserLaunchUsesSudo() {
        let launch = HelperLaunch.ssh(alias: "devbox", watchAs: .everyUser)
        #expect(launch.executable == "/usr/bin/ssh")
        #expect(Array(launch.arguments.suffix(3)) == ["sudo", "-n", "/usr/local/lib/swarmbar-helper"])
        #expect(launch.arguments.contains("devbox"))
        #expect(launch.arguments.contains("BatchMode=yes"))
        #expect(launch.environment == nil)
    }

    @Test("watching the login user runs the helper from its home with no sudo")
    func loginUserLaunchHasNoSudo() {
        let launch = HelperLaunch.ssh(alias: "devbox", watchAs: .loginUser)
        #expect(launch.arguments.last == #"exec python3 "$HOME/.swarmbar/swarmbar-helper""#)
        #expect(!launch.arguments.contains { $0.contains("sudo") })
        #expect(launch.arguments.contains("devbox"))
    }

    @Test("the login user install stays inside its home")
    func loginInstallStaysInHome() {
        let command = HelperLaunch.installCommand(for: .loginUser)
        #expect(command.contains("$HOME/.swarmbar"))
        #expect(!command.contains("sudo"))
        // BSD install refuses /dev/stdin, so a Darwin host would fail.
        #expect(!command.contains("/dev/stdin"))
    }

    @Test("the login user install command really installs the helper from stdin")
    func loginInstallRunsLocally() throws {
        let home = try freshHome()
        let bytes = Data("#!/usr/bin/env python3\nprint('synthetic helper')\n".utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", HelperLaunch.installCommand(for: .loginUser)]
        task.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        task.standardInput = stdin
        try task.run()
        try stdin.fileHandleForWriting.write(contentsOf: bytes)
        try stdin.fileHandleForWriting.close()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)

        let installed = home + "/.swarmbar/swarmbar-helper"
        #expect(FileManager.default.contents(atPath: installed) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: installed)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(!FileManager.default.fileExists(atPath: installed + ".tmp"))
    }

    @Test("the every user install pushes over the same channel, never scp")
    func everyUserInstallUsesStdin() {
        let command = HelperLaunch.installCommand(for: .everyUser)
        #expect(command == "sudo -n sh -c 'umask 077; cat > /usr/local/lib/swarmbar-helper.tmp && chmod 700 /usr/local/lib/swarmbar-helper.tmp && mv -f /usr/local/lib/swarmbar-helper.tmp /usr/local/lib/swarmbar-helper'")
        #expect(command.hasPrefix("sudo -n "))
        #expect(command.contains("/usr/local/lib/swarmbar-helper"))
        #expect(!command.contains("/dev/stdin"))
        #expect(!command.contains("scp"))
    }

    @Test("a local launch runs the script with the homes override")
    func localLaunchSetsHomes() {
        let launch = HelperLaunch.local(python: "/usr/bin/python3", script: "/tmp/h.py", homes: ["/home/u", "/home/v"])
        #expect(launch.executable == "/usr/bin/python3")
        #expect(launch.arguments == ["/tmp/h.py"])
        #expect(launch.environment == ["SWARMBAR_HELPER_HOMES": "/home/u:/home/v"])
    }

    @Test("arguments round-trip through JSON")
    func jsonValueRoundTrips() throws {
        let value = JSONValue.object([
            "s": .string("x"), "i": .int(3), "d": .double(1.5), "b": .bool(true),
            "a": .array([.int(1), .null]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("a ping round-trips through the real helper", .enabled(if: pythonAvailable))
    func pingRoundTrips() async throws {
        let channel = SSHChannel(launch: try localHelper())
        let data = try await channel.request("ping")
        let reply = try JSONDecoder().decode(PingReply.self, from: data)
        #expect(reply.ok)
        #expect(reply.protocol == 3)
        #expect(reply.sha256.count == 64)
        #expect(await channel.reachability == .reachable)
        await channel.shutdown()
    }

    @Test("concurrent requests each resolve to their own caller", .enabled(if: pythonAvailable))
    func concurrentRequestsResolveToTheirOwnIDs() async throws {
        struct EchoReply: Decodable { let id: Int; let value: String }
        let channel = SSHChannel(launch: try localHelper())
        let pairs = try await withThrowingTaskGroup(of: (String, String).self) { group in
            for index in 0..<8 {
                let sent = "caller-\(index)"
                group.addTask {
                    let data = try await channel.request("echo", ["value": .string(sent)])
                    return (sent, try JSONDecoder().decode(EchoReply.self, from: data).value)
                }
            }
            var pairs: [(String, String)] = []
            for try await pair in group { pairs.append(pair) }
            return pairs
        }
        #expect(pairs.count == 8)
        // An answer routed to the wrong caller would still decode; only the
        // echoed value shows whose answer it was.
        for (sent, received) in pairs {
            #expect(sent == received)
        }
        // All answered by one process: concurrency must not spawn a second.
        #expect(await channel.generation == 1)
        await channel.shutdown()
    }

    @Test("shutting down fails a request that is still waiting", .enabled(if: pythonAvailable))
    func killedHelperFailsPendingRequests() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        let pending = Task {
            try await channel.request("slow", ["delay": .double(30)])
        }
        // Long enough for the request to be written and parked.
        try await Task.sleep(for: .milliseconds(500))
        await channel.shutdown()
        await #expect {
            _ = try await pending.value
        } throws: { error in
            guard case SSHChannelError.closed = error else { return false }
            return true
        }
    }

    @Test("a new helper process advances the generation", .enabled(if: pythonAvailable))
    func generationAdvancesOnRestart() async throws {
        let channel = SSHChannel(launch: try localHelper())
        _ = try await channel.request("ping")
        #expect(await channel.generation == 1)
        await channel.shutdown()
        _ = try await channel.request("ping")
        #expect(await channel.generation == 2)
        await channel.shutdown()
    }

    @Test("a request past its timeout throws and the next one gets a fresh helper", .enabled(if: pythonAvailable))
    func timeoutKillsTheHelper() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        await #expect(throws: SSHChannelError.timedOut) {
            _ = try await channel.request("slow", ["delay": .double(5)], timeout: .milliseconds(300))
        }
        guard case .unreachable = await channel.reachability else {
            Issue.record("a timed out helper must leave the host unreachable")
            return
        }
        _ = try await channel.request("quick")
        #expect(await channel.generation == 2)
        #expect(await channel.reachability == .reachable)
        await channel.shutdown()
    }

    @Test("a timeout racing a late response resumes the request exactly once", .enabled(if: pythonAvailable))
    func timeoutRacingResponseDoesNotDoubleResume() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        // The response is due at the same moment the timeout fires, so
        // across these rounds both orders happen. A double resume of the
        // continuation traps, which would crash the test host rather than
        // fail an expectation; reaching the end is the assertion.
        for round in 0..<12 {
            let delay = 0.15
            let timeout = Duration.milliseconds(130 + (round % 5) * 10)
            do {
                _ = try await channel.request("race", ["delay": .double(delay)], timeout: timeout)
            } catch let error as SSHChannelError {
                #expect(error == .timedOut)
            }
        }
        _ = try await channel.request("after")
        await channel.shutdown()
    }

    @Test("a pushed event reaches the events stream", .enabled(if: pythonAvailable))
    func pushedEventIsYielded() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        _ = try await channel.request("emit")
        var events = channel.events.makeAsyncIterator()
        let event = try #require(await events.next())
        #expect(event.name == "hook")
        let object = try JSONSerialization.jsonObject(with: event.payload) as? [String: Any]
        #expect(object?["detail"] as? String == "synthetic")
        await channel.shutdown()
    }

    /// A held request dies with the process that held it, so a reader must
    /// hear about the exit itself rather than wait out a hold window.
    @Test("a torn-down helper says so on the events stream", .enabled(if: pythonAvailable))
    func teardownIsYielded() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        _ = try await channel.request("emit")
        var events = channel.events.makeAsyncIterator()
        let hook = try #require(await events.next())
        #expect(hook.name == "hook")
        #expect(hook.generation == 1)
        await channel.shutdown()
        let exited = try #require(await events.next())
        #expect(exited.name == HelperEvent.helperExited)
        #expect(exited.generation == 1)
    }

    @Test("a helper that keeps answering ok false backs off further each time", .enabled(if: pythonAvailable))
    func refusedSnapshotsGrowTheBackoff() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        var backoffs: [Int] = []
        for _ in 0..<3 {
            await #expect {
                _ = try await channel.snapshot()
            } throws: { error in
                guard case SSHChannelError.badResponse = error else { return false }
                return true
            }
            backoffs.append(await channel.currentBackoff)
        }
        // A reply that merely carries an id must not count as health, or
        // the backoff never grows and the reinstall at the cap never fires.
        #expect(backoffs == [2, 4, 8])
        await channel.shutdown()
    }

    @Test("a helper that exits on its own fails every waiting request once", .enabled(if: pythonAvailable))
    func helperExitFailsPendingRequests() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        _ = try await channel.request("warm")
        #expect(await channel.currentBackoff == 1)

        let parked = Task { try await channel.request("hang") }
        try await Task.sleep(for: .milliseconds(200))
        let dying = Task { try await channel.request("die") }

        for task in [parked, dying] {
            await #expect {
                _ = try await task.value
            } throws: { error in
                // The hint is stderr's LAST line, drained as it arrived.
                guard case SSHChannelError.closed(let message) = error else { return false }
                return message.hasSuffix(": synthetic last words")
            }
        }
        // One process went away, so one failure, however many requests
        // were waiting on it.
        #expect(await channel.currentBackoff == 2)
        guard case .unreachable = await channel.reachability else {
            Issue.record("an exited helper must leave the host unreachable")
            return
        }
        await channel.shutdown()
    }
}
