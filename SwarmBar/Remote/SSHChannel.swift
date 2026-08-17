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
        buffer = Data()
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
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw SSHChannelError.closed(error.localizedDescription)
        }
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer = Data()
    }

    private func write(_ text: String) throws {
        guard let input else { throw SSHChannelError.notRunning }
        do {
            try input.write(contentsOf: Data(text.utf8))
        } catch {
            throw SSHChannelError.closed(error.localizedDescription)
        }
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
                throw SSHChannelError.closed("connection closed by \(alias)")
            }
            buffer.append(chunk)
        }
    }
}
