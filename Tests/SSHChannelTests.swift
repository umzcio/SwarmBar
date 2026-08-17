import Foundation
import Testing
@testable import SwarmBar

@Suite("SSH channel")
struct SSHChannelTests {
    @Test("the install command pushes over the same channel, never scp")
    func installCommandUsesStdin() {
        let argv = SSHChannel.installCommand(helperPath: "/usr/local/lib/swarmbar-helper")
        let joined = argv.joined(separator: " ")
        #expect(joined.contains("/dev/stdin"))
        #expect(joined.contains("/usr/local/lib/swarmbar-helper"))
        #expect(joined.contains("sudo -n"))
        #expect(!joined.contains("scp"))
    }

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
        #expect(SSHChannel.backoffSeconds(afterFailures: 99) == 60)
    }
}
