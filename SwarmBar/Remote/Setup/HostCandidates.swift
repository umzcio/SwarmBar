import Foundation

/// Turns the aliases found in ssh config into the short list the wizard
/// shows, dropping the ones that are plainly not machines running agents.
enum HostCandidates {
    static let gitHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]

    /// Drops git forges, the `git` user (a forge or self-hosted remote
    /// either way), and any alias that resolves to the same hostname and port
    /// as an earlier one. An alias that did not resolve is kept: failing to
    /// look is not evidence that it is not a host.
    static func filter(_ aliases: [String], resolved: [String: SSHResolved]) -> [String] {
        struct Endpoint: Hashable { let hostname: String; let port: Int }
        var seen = Set<Endpoint>()
        var out: [String] = []
        for alias in aliases {
            guard let r = resolved[alias] else { out.append(alias); continue }
            if isGitHost(r) { continue }
            guard seen.insert(Endpoint(hostname: r.hostname, port: r.port)).inserted else { continue }
            out.append(alias)
        }
        return out
    }

    /// A git forge, or any host logged into as `git`.
    static func isGitHost(_ resolved: SSHResolved) -> Bool {
        gitHosts.contains(resolved.hostname.lowercased()) || resolved.user == "git"
    }

    /// Merges results that report the same hostname from the probe, keeping
    /// the one that connected (the first when both did, or neither). Results
    /// with no hostname cannot be compared, so they all stay. Generic so the
    /// probe's result type stays out of this file; order of survivors follows
    /// each hostname's first appearance.
    static func collapse<T>(
        _ results: [T], hostname: (T) -> String?, connected: (T) -> Bool
    ) -> [T] {
        var slot: [String: Int] = [:]
        var out: [T] = []
        for r in results {
            guard let name = hostname(r) else { out.append(r); continue }
            if let i = slot[name] {
                if !connected(out[i]) && connected(r) { out[i] = r }
            } else {
                slot[name] = out.count
                out.append(r)
            }
        }
        return out
    }

    /// The `--` ends option parsing, so an alias can never act as a flag
    /// even if one slipped past the parser's own check.
    static func resolveArguments(alias: String) -> [String] { ["-G", "--", alias] }

    /// Runs `ssh -G`, which only prints the resolved config and never
    /// contacts the host. A non-zero exit or a 5 second overrun gives nil.
    static func resolve(alias: String) async -> SSHResolved? {
        guard SSHConfigParser.isSafeAlias(alias) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<SSHResolved?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = resolveArguments(alias: alias)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    try? pipe.fileHandleForReading.close()
                    try? pipe.fileHandleForWriting.close()
                    cont.resume(returning: nil); return
                }
                // The parent's copy of the write end must close or EOF never comes.
                try? pipe.fileHandleForWriting.close()
                let reader = pipe.fileHandleForReading
                let box = OutputBox()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    box.set(reader.readDataToEndOfFile())
                    done.signal()
                }
                // Wait on the process, not the pipe: a grandchild holding the
                // pipe open must not hold this thread past the deadline.
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                if process.isRunning == false { exited.signal() }
                if exited.wait(timeout: .now() + 5) == .timedOut { process.terminate() }
                let drained = done.wait(timeout: .now() + 1) == .success
                if !drained { try? reader.close() }
                guard drained, !process.isRunning, process.terminationStatus == 0,
                      let text = String(data: box.get(), encoding: .utf8) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: SSHResolved.parse(text))
            }
        }
    }
}

/// Hands the reader thread's bytes back across a queue boundary.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
