import Foundation
import Testing
@testable import SwarmBar

@Suite("SSH channel")
struct SSHChannelTests {
    @Test("a response line is split off the buffer, leaving the remainder")
    func framesOneLine() {
        var buffer = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        let first = SSHChannel.takeLine(from: &buffer)
        #expect(first == Data("{\"a\":1}".utf8))
        let second = SSHChannel.takeLine(from: &buffer)
        #expect(second == Data("{\"b\":2}".utf8))
        #expect(SSHChannel.takeLine(from: &buffer) == nil)
    }

    @Test("a partial line is held until its newline arrives")
    func holdsPartialLine() {
        var buffer = Data("{\"a\":".utf8)
        #expect(SSHChannel.takeLine(from: &buffer) == nil)
        buffer.append(Data("1}\n".utf8))
        #expect(SSHChannel.takeLine(from: &buffer) == Data("{\"a\":1}".utf8))
    }

    @Test("backoff grows and is capped")
    func backoffIsCapped() {
        #expect(SSHChannel.backoffSeconds(afterFailures: 0) == 1)
        #expect(SSHChannel.backoffSeconds(afterFailures: 3) == 8)
        // The boundary where the formula transitions from an uncapped 64
        // to the capped 60, so a future change to either the cap or the
        // shift is caught.
        #expect(SSHChannel.backoffSeconds(afterFailures: 6) == 60)
        #expect(SSHChannel.backoffSeconds(afterFailures: 99) == 60)
        // Negative input must not fall through Swift's smart-shift
        // semantics (1 << -1 == 0) and silently violate "at least 1 second".
        #expect(SSHChannel.backoffSeconds(afterFailures: -5) == 1)
    }

    @Test("the stderr hint is the first non-empty line, truncated")
    func firstLineOfStderr() {
        #expect(SSHChannel.firstLine(of: Data()) == "")
        #expect(SSHChannel.firstLine(of: Data("\n\n".utf8)) == "")
        // ssh leads with a blank line often enough that taking line zero
        // blindly would produce an empty, useless hint.
        #expect(SSHChannel.firstLine(of: Data("\nPermission denied (publickey).\nlost connection\n".utf8))
                == "Permission denied (publickey).")
        // A dump is not a diagnostic: the row has room for a sentence.
        let long = String(repeating: "x", count: 500)
        #expect(SSHChannel.firstLine(of: Data(long.utf8)).count == 200)
        #expect(SSHChannel.firstLine(of: Data(long.utf8), limit: 20).count == 20)
    }

    @Test("reading a pipe returns what is there and never waits for more")
    func readAvailableDoesNotBlock() {
        let pipe = Pipe()
        // Nothing written and the write end still open: availableData would
        // park here forever. This must come straight back empty.
        #expect(SSHChannel.readAvailable(pipe.fileHandleForReading).isEmpty)

        try? pipe.fileHandleForWriting.write(contentsOf: Data("sudo: a password is required\n".utf8))
        let hint = SSHChannel.firstLine(of: SSHChannel.readAvailable(pipe.fileHandleForReading))
        #expect(hint == "sudo: a password is required")

        // And still non-blocking once drained.
        #expect(SSHChannel.readAvailable(pipe.fileHandleForReading).isEmpty)
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }
}
