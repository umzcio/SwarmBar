import Foundation
import Synchronization

enum RemoteReachability: Equatable, Sendable {
    case connecting
    case reachable
    case unreachable(String)
    /// The host answers but cannot be watched until something is set up on
    /// it, such as a helper that sudo will no longer run without a password.
    /// Kept apart from `.unreachable` so the row can say what to do rather
    /// than only that something is wrong.
    case needsSetup(String)
}

enum SSHChannelError: Error, Equatable {
    case notRunning
    case closed(String)
    case badResponse(String)
    case timedOut
}

/// A line the helper pushed on its own rather than in answer to a request.
/// The payload is the whole line, so a caller decodes whatever fields its
/// event carries without this type having to know them.
struct HelperEvent: Sendable {
    let name: String
    let payload: Data
}

/// The tail end of a helper's stderr, drained as it arrives. Draining keeps
/// a long-lived ssh from stalling once the pipe's buffer fills, and the
/// last line is the one worth showing: ssh's final word before it gives up
/// is what separates a missing NOPASSWD rule from an unauthorized key from
/// a host that is simply down.
final class StderrTail: Sendable {
    private struct State {
        var partial = Data()
        var last = ""
        var finished = false
    }

    private let state = Mutex(State())

    func append(_ chunk: Data) {
        state.withLock { state in
            state.partial.append(chunk)
            while let line = SSHChannel.takeLine(from: &state.partial) {
                let text = SSHChannel.firstLine(of: line)
                if !text.isEmpty { state.last = text }
            }
            // A stream that never sends a newline must not grow forever.
            if state.partial.count > 4096 {
                state.partial = Data(state.partial.suffix(4096))
            }
        }
    }

    func finish() {
        state.withLock { $0.finished = true }
    }

    /// The last non-empty line, at most 200 characters. An unterminated
    /// line counts, since it is the newest thing said.
    var hint: String {
        state.withLock { state in
            let pending = SSHChannel.firstLine(of: state.partial)
            return pending.isEmpty ? state.last : pending
        }
    }

    /// stdout and stderr close together when a process exits, but nothing
    /// orders their handlers, so the stdout side waits briefly for stderr
    /// to catch up before reading the hint.
    func waitForEnd(limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !state.withLock({ $0.finished }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// One long-lived helper process per host, with the helper as the remote
/// command. No listening ports anywhere: the ssh connection is the
/// authentication, which removes the token, the port collision and the
/// bastion problem at once.
///
/// Full duplex. Every request carries an id the helper echoes, so any number
/// of requests can be in flight at once and each answer finds its own
/// caller. A single reader per process owns stdout, splits it into lines and
/// routes them: a line with an id resumes the request waiting on it, and a
/// line with an event and no id goes to `events`.
actor SSHChannel {
    /// Readable from outside so the installer can tell a local helper,
    /// which is never pushed over ssh, from a remote one.
    nonisolated let launch: HelperLaunch
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    /// ssh's own stderr. Without it a missing NOPASSWD rule, an unauthorized
    /// key, a host key mismatch, a missing python3, a helper syntax error and
    /// a genuinely down host all collapse into the same "connection closed"
    /// and the row just says the host cannot be reached.
    private var errorOutput: FileHandle?
    private var stderrTail: StderrTail?
    /// Writes happen here, in order, rather than on the actor. A request
    /// that carries a large payload into a helper too busy to read it would
    /// otherwise block the actor, and every other request with it, until
    /// the pipe drained.
    private nonisolated let writer = DispatchQueue(label: "app.swarmbar.SSHChannel.writer")
    /// Feeds the current process's reader. Finishing it is what stops that
    /// reader, so a torn-down process cannot keep routing lines.
    private var chunkSink: AsyncStream<Data>.Continuation?
    private var failures = 0
    private var nextID = 1
    /// Every request still waiting on its answer. Each entry is removed
    /// before it is resumed, and only on this actor, so a response, a
    /// timeout, a process exit and a shutdown can race freely: whichever
    /// arrives first takes the continuation and the rest find nothing.
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]

    /// Counts helper processes started. Anything a caller learned from the
    /// helper belongs to the process that said it, so a caller that sees
    /// this change knows the helper restarted underneath it.
    private(set) var generation = 0
    private(set) var reachability: RemoteReachability = .connecting

    /// Events from every process this channel runs, across restarts, for
    /// the channel's whole life.
    nonisolated let events: AsyncStream<HelperEvent>
    private nonisolated let eventSink: AsyncStream<HelperEvent>.Continuation

    init(launch: HelperLaunch) {
        self.launch = launch
        (events, eventSink) = AsyncStream.makeStream(of: HelperEvent.self)
    }

    deinit {
        eventSink.finish()
        chunkSink?.finish()
        process?.terminate()
    }

    nonisolated static func backoffSeconds(afterFailures failures: Int) -> Int {
        min(60, 1 << min(max(failures, 0), 6))
    }

    /// Splits one newline-terminated frame off the buffer. Returns nil when
    /// no complete line has arrived yet, so a partial read is held rather
    /// than parsed as truncated JSON.
    nonisolated static func takeLine(from buffer: inout Data) -> Data? {
        guard let index = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = buffer[buffer.startIndex..<index]
        buffer = Data(buffer[buffer.index(after: index)...])
        return Data(line)
    }

    /// Sends one command and waits for the line that answers it. The line
    /// comes back undecoded, whatever its `ok`, because only the caller
    /// knows the shape its command returns.
    ///
    /// A request past `timeout` throws `.timedOut` and kills the helper. A
    /// helper that has stopped answering cannot be trusted with the next
    /// request either, and a fresh process is one spawn away.
    func request(
        _ command: String, _ arguments: [String: JSONValue] = [:],
        timeout: Duration = .seconds(30)
    ) async throws -> Data {
        let reply = try await exchange(command, arguments, timeout: timeout)
        // Only `ok: true` is health. A helper that answers every request
        // with an error is alive but not working, and counting its answers
        // as success would pin the backoff low and keep the reinstall that
        // waits for the cap from ever firing.
        if reply.ok { noteSuccess(generation: reply.generation) }
        return reply.line
    }

    func snapshot() async throws -> RemoteSnapshot {
        let reply = try await exchange("snapshot", [:], timeout: .seconds(30))
        let decoded: RemoteSnapshot
        do {
            decoded = try RemoteSnapshot.decode(reply.line)
            guard decoded.ok else { throw SSHChannelError.badResponse("ok is false") }
        } catch {
            // A failed process is counted where it fails, once however many
            // requests were waiting on it, so callers must not also call
            // noteFailure for a request error or `failures` double-counts.
            // A reply that does not decode is the one failure only this
            // caller can see.
            let failure = SSHChannelError.badResponse(String(decoding: reply.line.prefix(200), as: UTF8.self))
            noteFailure(String(describing: failure))
            throw failure
        }
        noteSuccess(generation: reply.generation)
        return decoded
    }

    /// One answered request. `ok` is read by the reader, off the actor, so
    /// a large reply is not parsed a second time here.
    private struct Reply: Sendable {
        let line: Data
        let ok: Bool
        let generation: Int
    }

    private func exchange(
        _ command: String, _ arguments: [String: JSONValue], timeout: Duration
    ) async throws -> Reply {
        try Task.checkCancellation()
        do {
            try start()
        } catch {
            noteFailure(String(describing: error))
            throw error
        }

        let id = nextID
        nextID += 1
        var fields = arguments
        fields["cmd"] = .string(command)
        fields["id"] = .int(id)
        let frame = try JSONEncoder().encode(JSONValue.object(fields)) + Data("\n".utf8)
        let generation = self.generation

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id, generation: generation)
                }
                send(frame, id: id, generation: generation)
            }
        } onCancel: {
            // A cancelled caller stops waiting, but the helper is fine and
            // the line it eventually sends is simply dropped as unclaimed.
            Task { await self.settle(id, .failure(CancellationError())) }
        }
    }

    /// The helper answered properly, so the host is healthy. Ignored for a
    /// process that has since been torn down or replaced, whose answer says
    /// nothing about the one running now.
    private func noteSuccess(generation: Int) {
        guard generation == self.generation, process != nil else { return }
        failures = 0
        reachability = .reachable
    }

    /// Stops the helper on purpose. Every waiting request fails with
    /// `.closed`, and none of it counts as a failure, since nothing went
    /// wrong with the host.
    func shutdown() {
        tearDown(failing: .closed("channel shut down"))
    }

    /// Whatever a pipe already holds, without ever waiting for more.
    ///
    /// `availableData` is the obvious call and it is wrong here: it blocks
    /// until bytes or EOF, so a child that is alive and quiet hangs the
    /// caller, and when the spawn itself failed the parent still holds the
    /// write end so EOF never comes at all. Switching the descriptor to
    /// non-blocking for one read has neither problem.
    nonisolated static func readAvailable(_ handle: FileHandle, limit: Int = 4096) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            return Data()
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = buffer.withUnsafeMutableBytes { raw in
            read(descriptor, raw.baseAddress, limit)
        }
        return count > 0 ? Data(buffer.prefix(count)) : Data()
    }

    /// The first non-empty line of a child's stderr, short enough to sit in
    /// an error payload. A diagnostic, not a dump: ssh is happy to print a
    /// dozen lines of host key warning and the row only has space to say
    /// which kind of failure this was.
    nonisolated static func firstLine(of data: Data, limit: Int = 200) -> String {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(limit)) }
        }
        return ""
    }

    /// Counts one failure, marks the host unreachable and kills the helper,
    /// failing whatever was still waiting on it.
    func noteFailure(_ message: String) {
        failures += 1
        reachability = .unreachable(message)
        tearDown(failing: .closed(message))
    }

    var currentBackoff: Int { Self.backoffSeconds(afterFailures: failures) }

    private var label: String {
        switch launch {
        case .ssh(let alias, _): alias
        case .local: "the local helper"
        }
    }

    private func start() throws {
        if let process, process.isRunning { return }
        if process != nil {
            // Exited, and its reader has not reported the EOF yet. Counted
            // here because that report will name an old generation and be
            // ignored.
            noteFailure(failureMessage("connection closed by \(label)"))
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch.executable)
        task.arguments = launch.arguments
        if let environment = launch.environment {
            task.environment = environment
        }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
        } catch {
            throw SSHChannelError.closed(error.localizedDescription)
        }

        // The handler runs on a dispatch queue Foundation owns, so the
        // blocking read never occupies the actor or a cooperative-pool
        // thread, and with a fleet of hosts each holding a quiet connection
        // open, parking one pool thread per host would starve the pool.
        // The stream keeps the chunks in order for the reader below.
        let tail = StderrTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                tail.finish()
            } else {
                tail.append(chunk)
            }
        }

        let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF. Left installed, the handler is called again and
                // again with nothing.
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(chunk)
            }
        }

        generation += 1
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errorOutput = stderr.fileHandleForReading
        stderrTail = tail
        chunkSink = sink

        let generation = self.generation
        let events = eventSink
        // Detached and holding the channel weakly, so the line parsing,
        // which for a snapshot is a megabyte of JSON, happens off the actor
        // and an abandoned channel is not kept alive by its own reader.
        Task.detached { [weak self] in
            var buffer = Data()
            for await chunk in chunks {
                buffer.append(chunk)
                // Only a chunk holding a newline can complete a line, so a
                // large reply arriving in pieces is not rescanned from the
                // start on every piece.
                guard chunk.contains(UInt8(ascii: "\n")) else { continue }
                while let line = Self.takeLine(from: &buffer) {
                    switch Self.frame(of: line) {
                    case .response(let id, let ok):
                        guard let self else { return }
                        await self.deliver(Reply(line: line, ok: ok, generation: generation), id: id)
                    case .event(let name):
                        events.yield(HelperEvent(name: name, payload: line))
                    case .unrouted:
                        // The helper answers a request it could not parse
                        // with no id, so nothing is waiting on it.
                        NSLog("SwarmBar: unrouted helper line: \(String(decoding: line.prefix(200), as: UTF8.self))")
                    }
                }
            }
            await tail.waitForEnd(limit: .milliseconds(250))
            await self?.readerEnded(generation: generation)
        }
    }

    private enum Frame {
        case response(Int, ok: Bool)
        case event(String)
        case unrouted
    }

    private struct Envelope: Decodable {
        let id: Int?
        let event: String?
        let ok: Bool?
    }

    private nonisolated static func frame(of line: Data) -> Frame {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            return .unrouted
        }
        if let id = envelope.id { return .response(id, ok: envelope.ok == true) }
        if let event = envelope.event { return .event(event) }
        return .unrouted
    }

    /// Hands an answer to whoever is waiting on it. Health is not judged
    /// here: carrying an id only proves the helper is alive, and the caller
    /// decides whether the answer was any good.
    private func deliver(_ reply: Reply, id: Int) {
        guard reply.generation == generation, process != nil else { return }
        settle(id, .success(reply))
    }

    /// stdout reached EOF, which means the process is gone or going.
    private func readerEnded(generation: Int) {
        guard generation == self.generation, process != nil else { return }
        noteFailure(failureMessage("connection closed by \(label)"))
    }

    private func expire(_ id: Int, generation: Int) {
        guard pending[id] != nil else { return }
        settle(id, .failure(SSHChannelError.timedOut))
        // Only the process the request was written to. If that one is
        // already gone and a fresh one is running, there is nothing to kill.
        guard generation == self.generation, process != nil else { return }
        noteFailure("\(label) stopped answering")
    }

    private func settle(_ id: Int, _ result: Result<Reply, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        continuation.resume(with: result)
    }

    private func tearDown(failing error: SSHChannelError) {
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        chunkSink?.finish()
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        stderrTail = nil
        chunkSink = nil
        for id in Array(pending.keys) {
            settle(id, .failure(error))
        }
    }

    private func send(_ frame: Data, id: Int, generation: Int) {
        guard let input else {
            settle(id, .failure(SSHChannelError.notRunning))
            return
        }
        writer.async { [weak self] in
            do {
                try input.write(contentsOf: frame)
            } catch {
                let reason = error.localizedDescription
                Task { await self?.writeFailed(id, generation: generation, reason: reason) }
            }
        }
    }

    /// A write that fails means the pipe is gone, so the process is too.
    /// The request fails here even if the reader has not noticed the exit
    /// yet, and the process is counted once, by whichever path gets there
    /// first.
    private func writeFailed(_ id: Int, generation: Int, reason: String) {
        let message = failureMessage(reason)
        settle(id, .failure(SSHChannelError.closed(message)))
        guard generation == self.generation, process != nil else { return }
        noteFailure(message)
    }

    /// Appends whatever ssh said to a failure message, so the row's reason
    /// separates a missing NOPASSWD rule from an unauthorized key from a
    /// host key mismatch from a host that is simply down.
    private func failureMessage(_ reason: String) -> String {
        let hint = stderrTail?.hint ?? ""
        guard !hint.isEmpty else {
            NSLog("SwarmBar: \(label) failed with no stderr: \(reason)")
            return reason
        }
        NSLog("SwarmBar: \(label) ssh said: \(hint)")
        return "\(reason): \(hint)"
    }
}
