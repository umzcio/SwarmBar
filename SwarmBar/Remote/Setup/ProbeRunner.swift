import Foundation

/// Runs the read-only probe against hosts for the setup wizard: the bundled
/// helper piped to `python3 - probe` over a one-shot ssh, then once more
/// under `sudo -n` when the first run says passwordless sudo works, for the
/// view of every user. Nothing is installed by this; the helper only ever
/// exists on the host as the program python reads from stdin.
actor ProbeRunner {
    typealias Outcome = (user: ProbeResult?, root: ProbeResult?, failure: HostProblem?)

    /// One finished ssh. `timedOut` is set when the deadline killed it, so
    /// whatever it printed before that is not mistaken for its answer.
    struct RunResult: Sendable, Equatable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    /// Runs ssh with these arguments, the bytes on its stdin, and a deadline
    /// in seconds. Injectable so tests never start ssh.
    typealias Runner = @Sendable (_ arguments: [String], _ stdin: Data, _ deadline: TimeInterval) async -> RunResult

    /// Probes in flight at once, as the spec sets it.
    static let maxConcurrent = 6
    /// End to end per ssh: twice ConnectTimeout, which leaves the helper
    /// plenty once a connection is up. ConnectTimeout alone does not bound
    /// a connection that goes quiet after the handshake.
    static let deadline: TimeInterval = 20
    /// The reply is one JSON object holding config texts of up to 256 KB
    /// each. Past these the rest is drained and dropped, so a host that
    /// prints without end cannot grow this process without end.
    static let maxStdout = 32 * 1024 * 1024
    static let maxStderr = 64 * 1024

    /// No keepalives, unlike HelperLaunch.sshOptions: a probe is one short
    /// exchange that the deadline already bounds.
    static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

    /// The `--` ends option parsing before the alias, as in every ssh argv
    /// the app builds. `-B` keeps python from writing bytecode caches, which
    /// Apple's python 3.9 otherwise does under ~/Library/Caches before the
    /// helper's first line runs.
    static func userArguments(alias: String) -> [String] {
        sshOptions + ["--", alias, "python3", "-B", "-", "probe"]
    }

    static func rootArguments(alias: String) -> [String] {
        sshOptions + ["--", alias, "sudo", "-n", "python3", "-B", "-", "probe"]
    }

    /// The view of every user under the narrow sudo rule, which lets the
    /// login user run exactly root's installed helper and nothing else. That
    /// copy runs as itself, so nothing goes on its stdin.
    static func narrowRootArguments(alias: String) -> [String] {
        sshOptions + ["--", alias, "sudo", "-n", HelperLaunch.rootHelperPath, "probe"]
    }

    private let helperSource: Data
    private let runner: Runner

    init(helperSource: Data, runner: Runner? = nil) {
        self.helperSource = helperSource
        self.runner = runner ?? ProbeRunner.sshRunner
    }

    func probe(alias: String) async -> Outcome {
        // An alias that ssh could read as an option never reaches an argv.
        guard SSHConfigParser.isSafeAlias(alias) else { return (nil, nil, .other("unsafe alias")) }
        let user: ProbeResult
        switch Self.interpret(await runner(Self.userArguments(alias: alias), helperSource, Self.deadline),
                              alias: alias) {
        case .answered(let result): user = result
        case .failed(let problem): return (nil, nil, problem)
        }
        guard user.sudoOK else {
            guard user.helper.contains(where: { $0.path == HelperLaunch.rootHelperPath }) else {
                return (user, nil, nil)
            }
            // The installed helper may predate the probe, or the rule may be
            // gone. Anything but a good answer is simply no view of every
            // user, which the assessment never reads as Ready.
            let run = await runner(Self.narrowRootArguments(alias: alias), Data(), Self.deadline)
            if case .answered(let root) = Self.interpret(run, alias: alias) { return (user, root, nil) }
            return (user, nil, nil)
        }
        // sudo worked a moment ago, so a root view that fails is a failure
        // to look, never a host with nothing on it.
        switch Self.interpret(await runner(Self.rootArguments(alias: alias), helperSource, Self.deadline),
                              alias: alias) {
        case .answered(let root): return (user, root, nil)
        case .failed(let problem): return (user, nil, problem)
        }
    }

    /// Probes every alias, at most `maxConcurrent` at a time, and yields
    /// each result as it finishes so each row can stop its spinner on its
    /// own. Ending the stream early cancels the probes still running.
    nonisolated func probeAll(_ aliases: [String]) -> AsyncStream<(String, Outcome)> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (String, Outcome).self) { group in
                    var pending = aliases[...]
                    for _ in 0..<min(Self.maxConcurrent, pending.count) {
                        let alias = pending.removeFirst()
                        group.addTask { (alias, await self.probe(alias: alias)) }
                    }
                    while let finished = await group.next() {
                        continuation.yield(finished)
                        if let alias = pending.popFirst(), !Task.isCancelled {
                            group.addTask { (alias, await self.probe(alias: alias)) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum Reply: Equatable {
        case answered(ProbeResult)
        case failed(HostProblem)
    }

    /// What one ssh said. The helper's JSON wins over stderr when there is
    /// one, because ssh and the remote shell can print warnings around a
    /// probe that still answered.
    static func interpret(_ run: RunResult, alias: String) -> Reply {
        if run.timedOut { return .failed(.timedOut) }
        let stderr = String(decoding: run.stderr, as: UTF8.self)
        if let line = jsonLine(in: run.stdout) {
            let decoder = JSONDecoder()
            if let envelope = try? decoder.decode(ProbeResult.Envelope.self, from: line), !envelope.ok {
                if let python = envelope.python, !supportsHelper(python: python) {
                    return .failed(.pythonTooOld(python))
                }
                return .failed(.other(envelope.error ?? "The probe failed on the host"))
            }
            if var result = try? decoder.decode(ProbeResult.self, from: line) {
                result.alias = alias
                // The probe itself may run on an older python and still
                // answer, but the helper that would be installed needs 3.9.
                guard supportsHelper(python: result.python) else {
                    return .failed(.pythonTooOld(result.python))
                }
                return .answered(result)
            }
        }
        if run.status == 0 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failed(.other("The host's reply couldn't be read"))
        }
        return .failed(SSHFailure.classify(stderr: stderr, exitStatus: run.status))
    }

    /// 3.9 or newer. A version that cannot be read is let through: the
    /// helper ran, and refusing on a parse would hide a working host.
    static func supportsHelper(python: String) -> Bool {
        let parts = python.split(separator: ".").prefix(2).map { Int($0) }
        guard parts.count == 2, let major = parts[0], let minor = parts[1] else { return true }
        return (major, minor) >= (3, 9)
    }

    private static func jsonLine(in data: Data) -> Data? {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let first = line.first(where: { $0 != UInt8(ascii: " ") }), first == UInt8(ascii: "{") {
                return Data(line)
            }
        }
        return nil
    }

    // MARK: The real ssh

    nonisolated static let sshRunner: Runner = { arguments, stdin, deadline in
        await runProcess(executable: "/usr/bin/ssh", arguments: arguments, stdin: stdin, deadline: deadline)
    }

    /// Any executable, so tests can drive the process plumbing with /bin/sh
    /// instead of ssh.
    nonisolated static func runProcess(
        executable: String, arguments: [String], stdin: Data, deadline: TimeInterval
    ) async -> RunResult {
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: run(executable: executable, arguments: arguments, stdin: stdin,
                                               deadline: deadline, handle: handle))
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// Blocking. The child is always reaped before this returns, and both
    /// reads are bounded in size and, after the child exits, in time.
    private nonisolated static func run(
        executable: String, arguments: [String], stdin: Data, deadline: TimeInterval, handle: ProcessHandle
    ) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            for pipe in [input, output, errors] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            return RunResult(status: -1, stdout: Data(),
                             stderr: Data("\(executable) could not start: \(error)".utf8), timedOut: false)
        }
        handle.set(process)
        // The parent's copies of the child's ends must close, or EOF never
        // comes on the reads and a dead reader never fails the write.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        // The helper is bigger than a pipe buffer, so it is written from its
        // own thread. A child that exits without reading fails the write
        // with EPIPE (SIGPIPE is ignored app-wide), which ends the thread.
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            try? writer.write(contentsOf: stdin)
            try? writer.close()
        }
        let stdout = BoundedReader(output.fileHandleForReading, limit: maxStdout)
        let stderr = BoundedReader(errors.fileHandleForReading, limit: maxStderr)

        var timedOut = false
        if exited.wait(timeout: .now() + deadline) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // Wait on the process, then give the reads a moment: a grandchild
        // holding a pipe open must not hold this thread past the deadline.
        let out = stdout.finish(within: 1)
        let err = stderr.finish(within: 1)
        let status = process.isRunning ? -1 : process.terminationStatus
        return RunResult(status: status, stdout: out, stderr: err, timedOut: timedOut)
    }
}

/// The running ssh, so a cancelled probe can stop it from another thread.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = cancelled
        lock.unlock()
        if stop { process.terminate() }
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}

/// Reads a pipe to EOF on its own thread, keeping at most `limit` bytes and
/// draining the rest so the child never blocks on a full pipe. It polls
/// rather than blocking in read, so it can be told to stop: an ssh
/// ControlMaster forked by this ssh can hold the pipe open long after the
/// ssh itself exits, and closing a descriptor another thread is reading is
/// a race on the descriptor number.
private final class BoundedReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)
    private let handle: FileHandle

    init(_ handle: FileHandle, limit: Int) {
        self.handle = handle
        DispatchQueue.global(qos: .utility).async { [self] in
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !isStopped {
                var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&request, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 { break }
                if ready == 0 { continue }
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if count <= 0 { break }
                lock.lock()
                if data.count < limit { data.append(contentsOf: buffer.prefix(min(count, limit - data.count))) }
                lock.unlock()
            }
            done.signal()
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// What was read, once EOF arrives or `seconds` pass. Either way the
    /// reading thread has finished and the descriptor is closed on return.
    func finish(within seconds: TimeInterval) -> Data {
        if done.wait(timeout: .now() + seconds) == .timedOut {
            lock.lock()
            stopped = true
            lock.unlock()
            done.wait()
        }
        try? handle.close()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
