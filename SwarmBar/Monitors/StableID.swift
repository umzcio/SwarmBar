import CryptoKit
import Foundation

/// Derives a deterministic UUID from an arbitrary string session id. Some
/// tools mint ids that aren't UUIDs (OpenCode's "ses_...", Kimi's
/// "session_<uuid>"), but AgentSession needs a stable UUID across polls so
/// re-discovering the same session doesn't mint a new identity every time.
/// Hashing the string with SHA256 and taking the first 16 bytes gives a
/// stable, collision-resistant UUID without needing to remember a mapping.
enum StableID {
    nonisolated static func uuid(for string: String) -> UUID {
        let digest = SHA256.hash(data: Data(string.utf8))
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for byte in digest.prefix(16) { bytes.append(byte) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
