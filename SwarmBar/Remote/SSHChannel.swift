import Foundation

enum RemoteReachability: Equatable, Sendable {
    case connecting
    case reachable
    case unreachable(String)
}

enum SSHChannelError: Error, Equatable {
    case notRunning
    case closed(String)
    case badResponse(String)
    case busy
}

/// One long-lived ssh connection per host, with the helper as the remote
/// command. No listening ports anywhere: the ssh connection is the
/// authentication, which removes the token, the port collision and the
/// bastion problem at once.
actor SSHChannel {
    private let alias: String
    private let helperPath: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    /// ssh's own stderr. Without it a missing NOPASSWD rule, an unauthorized
    /// key, a host key mismatch, a missing python3, a helper syntax error and
    /// a genuinely down host all collapse into the same "connection closed"
    /// and the row just says the host cannot be reached.
    private var errorOutput: FileHandle?
    private var buffer = Data()
    private var failures = 0
    /// Guards snapshot() against actor reentrancy. Two overlapping calls
    /// would both write to the same stdin and each suspend on its own
    /// detached read of the same pipe, racing over which call's bytes land
    /// in whose buffer. The single monitor loop never calls in twice, so a
    /// concurrent call means a bug in a future caller; it should be loud
    /// (an error) rather than silently serialized or interleaved.
    private var requestInFlight = false

    private(set) var reachability: RemoteReachability = .connecting

    init(alias: String, helperPath: String = "/usr/local/lib/swarmbar-helper") {
        self.alias = alias
        self.helperPath = helperPath
    }

    /// Installed by pushing over the same ssh connection rather than a
    /// separate scp step, so there is only ever one channel to authorize.
    nonisolated static func installCommand(helperPath: String) -> [String] {
        ["sudo -n install -m 700 -o root -g root /dev/stdin \(helperPath)"]
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

    func snapshot() async throws -> RemoteSnapshot {
        guard !requestInFlight else { throw SSHChannelError.busy }
        requestInFlight = true
        defer { requestInFlight = false }

        do {
            try start()
            try write(#"{"cmd":"snapshot"}"# + "\n")
            let line = try await readLine()
            let decoded: RemoteSnapshot
            do {
                decoded = try RemoteSnapshot.decode(line)
            } catch {
                throw SSHChannelError.badResponse(String(decoding: line.prefix(200), as: UTF8.self))
            }
            failures = 0
            reachability = .reachable
            return decoded
        } catch {
            // snapshot() owns its own failure bookkeeping so reachability
            // cannot lag behind a caller that forgets to report a failure
            // separately. Callers must not also call noteFailure for this
            // same error, or `failures` double-counts; the monitor loop
            // only reads currentBackoff after a catch.
            noteFailure(String(describing: error))
            throw error
        }
    }

    func shutdown() {
        process?.terminate()
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        buffer = Data()
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

    func noteFailure(_ message: String) {
        failures += 1
        reachability = .unreachable(message)
        shutdown()
    }

    var currentBackoff: Int { Self.backoffSeconds(afterFailures: failures) }

    private func start() throws {
        if let process, process.isRunning { return }
        shutdown()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            alias,
            "sudo", "-n", helperPath,
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
        } catch {
            throw SSHChannelError.closed(error.localizedDescription)
        }
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errorOutput = stderr.fileHandleForReading
        buffer = Data()
    }

    private func write(_ text: String) throws {
        guard let input else { throw SSHChannelError.notRunning }
        do {
            try input.write(contentsOf: Data(text.utf8))
        } catch {
            throw SSHChannelError.closed(failureMessage(error.localizedDescription))
        }
    }

    /// Appends whatever ssh said to a failure message, so the row's reason
    /// separates a missing NOPASSWD rule from an unauthorized key from a
    /// host key mismatch from a host that is simply down.
    private func failureMessage(_ reason: String) -> String {
        guard let errorOutput else { return reason }
        let hint = Self.firstLine(of: Self.readAvailable(errorOutput))
        guard !hint.isEmpty else {
            NSLog("SwarmBar: \(alias) failed with no stderr: \(reason)")
            return reason
        }
        NSLog("SwarmBar: \(alias) ssh said: \(hint)")
        return "\(reason): \(hint)"
    }

    /// `availableData` blocks. Inside an actor that would occupy a
    /// cooperative-pool thread for the whole round trip, and with a fleet
    /// of hosts that starves the pool. So the blocking read happens on a
    /// detached task, mirroring how `ClaudeCodeMonitor` already pushes its
    /// blocking file work off the caller with `Task.detached`.
    private func readLine() async throws -> Data {
        guard let output else { throw SSHChannelError.notRunning }
        while true {
            if let line = Self.takeLine(from: &buffer) { return line }
            let chunk = await Task.detached { output.availableData }.value
            if chunk.isEmpty {
                throw SSHChannelError.closed(
                    failureMessage("connection closed by \(alias)"))
            }
            buffer.append(chunk)
        }
    }
}
