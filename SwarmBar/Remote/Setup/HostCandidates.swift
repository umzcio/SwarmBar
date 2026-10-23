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
            if gitHosts.contains(r.hostname.lowercased()) || r.user == "git" { continue }
            guard seen.insert(Endpoint(hostname: r.hostname, port: r.port)).inserted else { continue }
            out.append(alias)
        }
        return out
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

    /// Runs `ssh -G`, which only prints the resolved config and never
    /// contacts the host. A non-zero exit or a 5 second overrun gives nil.
    static func resolve(alias: String) async -> SSHResolved? {
        await withCheckedContinuation { (cont: CheckedContinuation<SSHResolved?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-G", alias]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { cont.resume(returning: nil); return }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
                // Output is a few KB, well under the pipe buffer, so reading
                // to EOF after launch cannot deadlock.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: SSHResolved.parse(text))
            }
        }
    }
}
