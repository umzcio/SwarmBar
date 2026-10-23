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
/// first when asked to `emit`.
private func scriptedHelper() throws -> HelperLaunch {
    let source = """
    import json, sys, time
    for line in sys.stdin:
        request = json.loads(line)
        if request.get("cmd") == "emit":
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
        #expect(command.contains("/dev/stdin"))
        #expect(!command.contains("sudo"))
    }

    @Test("the every user install pushes over the same channel, never scp")
    func everyUserInstallUsesStdin() {
        let command = HelperLaunch.installCommand(for: .everyUser)
        #expect(command == "sudo -n install -m 700 -o root -g root /dev/stdin /usr/local/lib/swarmbar-helper")
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
        defer { Task { await channel.shutdown() } }
        let data = try await channel.request("ping")
        let reply = try JSONDecoder().decode(PingReply.self, from: data)
        #expect(reply.ok)
        #expect(reply.protocol == 3)
        #expect(reply.sha256.count == 64)
        #expect(await channel.reachability == .reachable)
    }

    @Test("concurrent requests each resolve to their own id", .enabled(if: pythonAvailable))
    func concurrentRequestsResolveToTheirOwnIDs() async throws {
        let channel = SSHChannel(launch: try localHelper())
        defer { Task { await channel.shutdown() } }
        let ids = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let data = try await channel.request("ping")
                    return try JSONDecoder().decode(PingReply.self, from: data).id
                }
            }
            var ids: [Int] = []
            for try await id in group { ids.append(id) }
            return ids
        }
        #expect(Set(ids).count == 2)
        // Both answered by one process: concurrency must not spawn a second.
        #expect(await channel.generation == 1)
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
        defer { Task { await channel.shutdown() } }
        await #expect(throws: SSHChannelError.timedOut) {
            _ = try await channel.request("slow", ["delay": .double(5)], timeout: .milliseconds(300))
        }
        _ = try await channel.request("quick")
        #expect(await channel.generation == 2)
    }

    @Test("a timeout racing a late response resumes the request exactly once", .enabled(if: pythonAvailable))
    func timeoutRacingResponseDoesNotDoubleResume() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        defer { Task { await channel.shutdown() } }
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
    }

    @Test("a pushed event reaches the events stream", .enabled(if: pythonAvailable))
    func pushedEventIsYielded() async throws {
        let channel = SSHChannel(launch: try scriptedHelper())
        defer { Task { await channel.shutdown() } }
        _ = try await channel.request("emit")
        var events = channel.events.makeAsyncIterator()
        let event = try #require(await events.next())
        #expect(event.name == "hook")
        let object = try JSONSerialization.jsonObject(with: event.payload) as? [String: Any]
        #expect(object?["detail"] as? String == "synthetic")
    }
}
