import Foundation
import Synchronization
import Testing
@testable import SwarmBar

/// A client the listener can be driven through without a socket.
private final class FakeClient: HookClient, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Data?, Bool) -> Void)?
    private var _responses: [Data] = []
    private var _cancelled = false

    func start(on queue: DispatchQueue, onData: @escaping @Sendable (Data?, Bool) -> Void) {
        lock.withLock { handler = onData }
    }

    /// Delivers bytes as the transport would, on the listener's queue.
    func send(_ text: String, eof: Bool = false, via listener: HookListener) {
        let handler = lock.withLock { self.handler }
        listener.queue.sync { handler?(Data(text.utf8), eof) }
    }

    func respond(_ data: Data, completion: (@Sendable (Bool) -> Void)?) {
        lock.withLock { _responses.append(data) }
        completion?(true)
        cancel()
    }

    func cancel() { lock.withLock { _cancelled = true } }
    var isGone: Bool { lock.withLock { _cancelled } }
    var responses: [Data] { lock.withLock { _responses } }
}

private func request(_ event: String = "Stop", body: String = "{}", token: String? = nil) -> String {
    let tokenLine = token.map { "X-SwarmBar-Token: \($0)\r\n" } ?? ""
    return "POST /hook/\(event) HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\(tokenLine)\r\n\(body)"
}

private final class Deliveries: Sendable {
    let paths = Mutex<[String]>([])
    let clients = Mutex<[ObjectIdentifier]>([])
}

@MainActor
struct HookRequestReaderTests {
    /// A trickled request costs work in proportion to its size: the
    /// header terminator is never searched for twice in the same bytes.
    @Test func aTrickledHeaderIsScannedOnce() {
        let padding = String(repeating: "x", count: 15_000)
        let text = "POST /hook/Stop HTTP/1.1\r\nX-Pad: \(padding)\r\nContent-Length: 2\r\n\r\n{}"
        var reader = HookRequestReader()
        var outcome = HookServer.ParseOutcome.incomplete
        for byte in Data(text.utf8) {
            outcome = reader.append(Data([byte]))
        }
        guard case .complete(let parsed) = outcome else {
            Issue.record("expected a complete parse"); return
        }
        #expect(parsed.path == "/hook/Stop")
        #expect(reader.scannedBytes < 4 * text.utf8.count)
    }

    @Test func anEndlessHeaderIsRefused() {
        var reader = HookRequestReader()
        let outcome = reader.append(Data(("POST /hook/Stop HTTP/1.1\r\nX: "
            + String(repeating: "a", count: HookRequestReader.maxHeaderBytes + 1)).utf8))
        guard case .malformed = outcome else { Issue.record("expected malformed"); return }
    }

    @Test func aBodyArrivingInPiecesCompletes() {
        var reader = HookRequestReader()
        let body = "{\"session_id\":\"abc\"}"
        guard case .incomplete = reader.append(Data(
            "POST /hook/Stop HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n{\"sess".utf8))
        else { Issue.record("expected incomplete"); return }
        guard case .complete(let parsed) = reader.append(Data("ion_id\":\"abc\"}".utf8)) else {
            Issue.record("expected a complete parse"); return
        }
        #expect(parsed.body["session_id"] as? String == "abc")
    }
}

@MainActor
struct HookListenerLimitTests {
    private func listener(
        maxOpen: Int = 4, timeout: DispatchTimeInterval = .seconds(10), into deliveries: Deliveries
    ) -> HookListener {
        HookListener(
            limits: .init(maxOpenRequests: maxOpen, requestTimeout: timeout),
            deliver: { delivery in
                deliveries.paths.withLock { $0.append(delivery.request.path) }
                deliveries.clients.withLock { $0.append(ObjectIdentifier(delivery.client)) }
            },
            clientGone: {})
    }

    /// Connections that never finish sending are capped, and a flood on
    /// the loopback port leaves the bridges' socket untouched.
    @Test func halfOpenConnectionsAreCappedPerTransport() {
        let deliveries = Deliveries()
        let listener = listener(into: deliveries)
        let flood = (0..<6).map { _ in FakeClient() }
        for client in flood { listener.adopt(client, transport: .loopback, token: "t") }
        listener.queue.sync {}
        #expect(flood.prefix(4).allSatisfy { !$0.isGone })
        #expect(flood.suffix(2).allSatisfy { $0.isGone })
        #expect(listener.openRequests(on: .loopback) == 4)

        let bridge = FakeClient()
        listener.adopt(bridge, transport: .ownerSocket, token: nil)
        listener.queue.sync {}
        bridge.send(request("PermissionRequest"), via: listener)
        #expect(deliveries.paths.withLock { $0 } == ["/hook/PermissionRequest"])
    }

    /// A connection that has not sent its request in time is closed. One
    /// that has, and is waiting on a decision, is not.
    @Test func onlyUnfinishedRequestsTimeOut() async throws {
        let deliveries = Deliveries()
        let listener = listener(timeout: .milliseconds(50), into: deliveries)
        let idle = FakeClient()
        let held = FakeClient()
        listener.adopt(idle, transport: .ownerSocket, token: nil)
        listener.adopt(held, transport: .ownerSocket, token: nil)
        listener.queue.sync {}
        idle.send("POST /hook/Stop HTTP/1.1\r\n", via: listener)
        held.send(request("PermissionRequest"), via: listener)
        try await Task.sleep(for: .milliseconds(300))
        listener.queue.sync {}
        #expect(idle.isGone)
        #expect(!held.isGone)
        #expect(listener.openRequests(on: .ownerSocket) == 0)
    }

    /// The loopback port needs the token, checked before anything reaches
    /// the main actor. The owner-only socket needs none.
    @Test func theLoopbackPortNeedsTheToken() {
        let deliveries = Deliveries()
        let listener = listener(into: deliveries)
        let wrong = FakeClient()
        listener.adopt(wrong, transport: .loopback, token: "secret")
        listener.queue.sync {}
        wrong.send(request(token: "guess"), via: listener)
        #expect(wrong.responses == [Data("{}".utf8)])
        #expect(deliveries.paths.withLock { $0 }.isEmpty)

        let right = FakeClient()
        listener.adopt(right, transport: .loopback, token: "secret")
        listener.queue.sync {}
        right.send(request(token: "secret"), via: listener)
        let socket = FakeClient()
        listener.adopt(socket, transport: .ownerSocket, token: nil)
        listener.queue.sync {}
        socket.send(request(), via: listener)
        #expect(deliveries.paths.withLock { $0 }.count == 2)
    }

    @Test func aMalformedRequestIsDropped() {
        let deliveries = Deliveries()
        let listener = listener(into: deliveries)
        let client = FakeClient()
        listener.adopt(client, transport: .ownerSocket, token: nil)
        listener.queue.sync {}
        client.send("GET / HTTP/1.1\r\n\r\n", via: listener)
        #expect(client.isGone)
        #expect(deliveries.paths.withLock { $0 }.isEmpty)
    }
}

/// The bridges and the owner-only socket, end to end, against a home in a
/// temporary folder. Nothing here touches the loopback port.
@MainActor
struct OwnerSocketBridgeTests {
    /// A home short enough that the socket path fits in sun_path.
    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: "/tmp/sbh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func socketPath(_ home: URL) -> String {
        home.appendingPathComponent("Library/Application Support/SwarmBar/run/hook.sock").path
    }

    private func serve(at path: String, answer: String, into deliveries: Deliveries) throws -> (UnixHookSocket, HookListener) {
        let listener = HookListener(
            deliver: { delivery in
                deliveries.paths.withLock { $0.append(delivery.request.path) }
                delivery.client.respond(Data(answer.utf8), completion: nil)
            },
            clientGone: {})
        let socket = UnixHookSocket(path: path)
        try socket.start(queue: listener.queue) { client in
            listener.adopt(client, transport: .ownerSocket, token: nil)
        }
        return (socket, listener)
    }

    private func run(_ script: String, ext: String, home: URL, event: String) throws -> String {
        let url = try #require(Bundle.main.url(forResource: script, withExtension: ext))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path, event]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("{\"session_id\":\"x\"}".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func theClaudeBridgePrintsWhatTheSocketAnswers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let deliveries = Deliveries()
        let (socket, _) = try serve(at: socketPath(home), answer: "{\"decided\":true}", into: deliveries)
        defer { socket.stop() }

        let out = try run("swarmbar-hook", ext: "sh", home: home, event: "PermissionRequest")
        #expect(out == "{\"decided\":true}")
        #expect(deliveries.paths.withLock { $0 } == ["/hook/PermissionRequest"])

        // The folder and the socket are this user's alone.
        let run = try FileManager.default.attributesOfItem(
            atPath: (socketPath(home) as NSString).deletingLastPathComponent)
        #expect((run[.posixPermissions] as? Int) == 0o700)
        let sock = try FileManager.default.attributesOfItem(atPath: socketPath(home))
        #expect((sock[.posixPermissions] as? Int) == 0o600)
    }

    @Test func theKimiBridgeRelaysAndPrintsNothing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let deliveries = Deliveries()
        let (socket, _) = try serve(at: socketPath(home), answer: "{}", into: deliveries)
        defer { socket.stop() }
        let out = try run("swarmbar-kimi-hook", ext: "sh", home: home, event: "Stop")
        #expect(out.isEmpty)
        #expect(deliveries.paths.withLock { $0 } == ["/hook/Stop"])
    }

    /// With no socket of this user's, the bridges send nothing anywhere
    /// and print nothing, so the agent shows its own prompt.
    @Test func withoutTheSocketTheBridgesFailOpen() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try run("swarmbar-hook", ext: "sh", home: home, event: "PermissionRequest").isEmpty)

        // Something that is not a socket at the path is not SwarmBar.
        let path = socketPath(home)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{\"hookSpecificOutput\":{}}".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try run("swarmbar-hook", ext: "sh", home: home, event: "PermissionRequest").isEmpty)
        // And the server will not delete it to take its place.
        #expect(throws: UnixHookSocket.Failure.self) {
            try UnixHookSocket(path: path).start(queue: .main) { _ in }
        }
    }

    /// A socket another running copy is serving stays that copy's.
    @Test func aLiveSocketIsNotTakenOver() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let deliveries = Deliveries()
        let (first, _) = try serve(at: socketPath(home), answer: "{}", into: deliveries)
        defer { first.stop() }
        #expect(throws: UnixHookSocket.Failure.self) {
            try UnixHookSocket(path: socketPath(home)).start(queue: .main) { _ in }
        }
    }

    /// The local bridges never reach for a port, and never carry the
    /// token on a command line where `ps` would show it.
    @Test func localBridgesUseOnlyTheOwnerSocket() throws {
        let names = [("swarmbar-hook", "sh"), ("swarmbar-kimi-hook", "sh"), ("swarmbar-opencode", "js")]
        for (name, ext) in names {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: ext))
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains(IntegrationManager.bridgeMarker), "\(name) has no marker")
            #expect(text.contains("SwarmBar/run"), "\(name)")
            #expect(text.contains("--unix-socket") || text.contains("socketPath"), "\(name)")
            #expect(!text.contains("127.0.0.1"), "\(name) reaches for loopback")
            #expect(!text.contains("48620"), "\(name) reaches for the port")
            #expect(!text.contains("X-SwarmBar-Token"), "\(name) sends the token")
            #expect(!text.contains("hook-token"), "\(name) reads the token")
        }
    }

    /// OpenCode 2 loads only `export default { id, setup }` and refused the
    /// old named plugin function outright ("Plugin must export a default
    /// definition with an id and an effect or setup function"). OpenCode
    /// 1.17+ reads the same default's server(). Both plugins carry both.
    @Test func openCodePluginsLoadInBothPluginSystems() throws {
        for name in ["swarmbar-opencode", "swarmbar-remote-opencode"] {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "js"))
            let text = try String(contentsOf: url, encoding: .utf8)
            let exports = text.split(separator: "\n").filter { $0.hasPrefix("export ") }
            #expect(exports.contains { $0.hasPrefix("export default { id: \"swarmbar") && $0.contains("server") && $0.contains("setup") },
                "\(name): \(exports)")
            #expect(!exports.contains { $0.contains("Plugin = async") }, "\(name) still has a 1.x-only export")
            #expect(text.contains("async function setup(opencode)"), "\(name)")
            #expect(text.contains("async function server({ client, directory })"), "\(name)")
            #expect(text.contains("opencode.permission.reply("), "\(name)")
        }
    }
}
