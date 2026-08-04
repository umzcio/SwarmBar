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

    static var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// Reads the existing token or mints one. Returns nil only if the
    /// token cannot be persisted, in which case the caller must run
    /// unauthenticated rather than refusing hooks (fail open).
    static func loadOrCreate() -> String? {
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
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
            try token.write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            return nil
        }
        return token
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
