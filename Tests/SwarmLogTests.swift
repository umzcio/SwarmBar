import Foundation
import Testing
@testable import SwarmBar

@Suite("Logging", .serialized)
struct SwarmLogTests {
    /// What NSLog writes to stderr while `body` runs. The test host's
    /// stderr is swapped for a pipe and put back afterwards.
    private func capturingStderr(_ body: () -> Void) -> String {
        let pipe = Pipe()
        let saved = dup(STDERR_FILENO)
        fflush(stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        body()
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(saved)
        try? pipe.fileHandleForWriting.close()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Every kind of outside text that reaches the log: a host's warning
    /// (a directory name the host's users chose), an unrouted helper line,
    /// an ssh stderr line and a hook rid. Each carries conversions that,
    /// read as a format, make NSLog dereference arguments never passed.
    @Test("text from outside the app is logged literally and never read as a format")
    func percentSequencesAreLiteral() {
        let messages = [
            "SwarmBar: devbox reported warnings: [\"skipped /home/x/.claude%@%@%s%s%n: looks like a backup\"]",
            "SwarmBar: unrouted helper line: {\"oops\": \"%s%s%s%s%@\"}",
            "SwarmBar: devbox ssh said: Permission denied %@%s%x%n",
            "SwarmBar: hook_reply for rid-%@%s%n failed: closed",
        ]
        let output = capturingStderr {
            for message in messages { SwarmLog.log(message) }
        }
        for message in messages {
            #expect(output.contains(String(message.dropFirst("SwarmBar: ".count))),
                    "not logged literally: \(message)")
        }
    }

    /// The rule as a check rather than a convention: NSLog appears in one
    /// file, the one whose format is a constant. Any other call would be
    /// one interpolation away from the crash above.
    @Test("NSLog is called only through SwarmLog")
    func nsLogHasOneCaller() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwarmBar")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var callers: [String] = []
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            scanned += 1
            guard file.lastPathComponent != "SwarmLog.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("NSLog(") || text.contains("NSLogv(") {
                callers.append(file.lastPathComponent)
            }
        }
        #expect(scanned > 50, "the app's sources were not found beside the tests")
        #expect(callers.isEmpty, "NSLog called directly in \(callers)")
    }
}
