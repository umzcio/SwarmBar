import Foundation
import Security

/// A per install secret shared with the bridge scripts, so the hook port
/// only accepts events from bridges this app installed. Stored beside the
/// installed scripts in Application Support with owner-only permissions.
/// Never logged, never written into a config file that is committed.
enum HookToken {
    private static let fileName = "hook-token"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwarmBar")
    }

    /// The token generation this build accepts. Bumped once, by the build
    /// that moved the bridges to the owner-only socket: until then every
    /// bridge sent the token in clear to whatever held 127.0.0.1:48620,
    /// and another account could hold it while SwarmBar was not running.
    /// A token from before is therefore treated as known and replaced.
    static let generation = "2"

    /// Reads this generation's token or mints one, replacing any token
    /// from before it. Nil only if the token cannot be persisted, and the
    /// loopback port is then not opened at all: it would otherwise take
    /// requests with no check from every account and every web page.
    ///
    /// `directory` is a seam for tests, which must never rotate the token
    /// a running copy of the app and its bridges are using.
    static func loadOrCreate(in directory: URL = directory) -> String? {
        let fileURL = directory.appendingPathComponent(fileName)
        let generationURL = directory.appendingPathComponent(fileName + ".generation")
        let current = (try? String(contentsOf: generationURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == generation
        if current, let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { return nil }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try writeOwnerOnly(token, to: fileURL)
            try writeOwnerOnly(generation, to: generationURL)
        } catch {
            return nil
        }
        return token
    }

    /// Created owner-only before any bytes land in it, then moved into
    /// place, so the secret is never readable by others even briefly.
    private static func writeOwnerOnly(_ text: String, to url: URL) throws {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Length-independent equality, so a comparison cannot leak the token
    /// through timing.
    static func matches(_ candidate: String?, _ expected: String) -> Bool {
        guard let candidate else { return false }
        let a = Array(candidate.utf8), b = Array(expected.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? Int(a[index]) : 0
            let y = index < b.count ? Int(b[index]) : 0
            difference |= x ^ y
        }
        return difference == 0
    }
}
