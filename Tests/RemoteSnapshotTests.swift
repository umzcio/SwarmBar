import Foundation
import Testing
@testable import SwarmBar

@Suite("Remote snapshot decoding")
struct RemoteSnapshotTests {
    private func fixture() throws -> RemoteSnapshot {
        let url = try #require(Bundle(for: BundleMarker.self)
            .url(forResource: "remote-snapshot-v3", withExtension: "json"))
        return try RemoteSnapshot.decode(Data(contentsOf: url))
    }

    private func file(_ snapshot: RemoteSnapshot, endingWith suffix: String) throws -> RemoteFileRecord {
        try #require(snapshot.files.first { $0.path.hasSuffix(suffix) })
    }

    @Test("decodes the protocol 3 envelope")
    func decodesEnvelope() throws {
        let snapshot = try fixture()
        #expect(snapshot.ok)
        #expect(snapshot.protocolVersion == 3)
        #expect(snapshot.stream == "0123456789abcdef")
        #expect(snapshot.hostname == "devbox")
        #expect(snapshot.system == "Linux")
        #expect(snapshot.homes == [RemoteHome(path: "/home/u", user: "u"), RemoteHome(path: "/root", user: "root")])
        #expect(snapshot.files.count == 4)
        #expect(snapshot.dirs.count == 10)
        #expect(snapshot.omitted.map(\.reason) == ["no complete record yet"])
        #expect(snapshot.warnings == ["cannot read open files of pid 4300"])
        #expect(!snapshot.processesFailed)
    }

    @Test("chunks decode to their offsets and exact bytes, the tail starting on a newline")
    func chunksDecode() throws {
        let transcript = try file(try fixture(), endingWith: "11111111-1111-1111-1111-111111111111.jsonl")
        #expect(transcript.reset)
        #expect(transcript.created == nil)
        #expect(transcript.chunks.map(\.offset) == [0, 200_000])
        let head = String(decoding: transcript.chunks[0].data, as: UTF8.self)
        #expect(head.hasPrefix(#"{"type":"user""#))
        #expect(head.hasSuffix("\n"))
        let tail = transcript.chunks[1].data
        #expect(tail.first == UInt8(ascii: "\n"))
        // The half-written last line ships too; the mirror must hold the
        // file's true bytes through its true size.
        #expect(tail.last != UInt8(ascii: "\n"))
        #expect(transcript.size == 200_000 + tail.count)
    }

    @Test("a growth chunk keeps its offset and the file keeps its creation time")
    func growthChunk() throws {
        let rollout = try file(try fixture(), endingWith: "22222222-2222-2222-2222-222222222222.jsonl")
        #expect(!rollout.reset)
        #expect(rollout.created == 1_792_654_800.75)
        #expect(rollout.chunks.map(\.offset) == [4096])
    }

    @Test("an unchanged file is still listed, with no chunks")
    func unchangedFileIsListed() throws {
        let index = try file(try fixture(), endingWith: "/.kimi-code/session_index.jsonl")
        #expect(index.chunks.isEmpty)
        #expect(!index.reset)
        #expect(index.size == 512)
    }

    @Test("dirs carry their times")
    func dirsDecode() throws {
        let snapshot = try fixture()
        let dir = try #require(snapshot.dirs.first { $0.path == "/root/.codex/sessions/2026/10/22" })
        #expect(dir.mtime == 1_792_654_800.75)
        #expect(dir.created == nil)
    }

    @Test("processes carry their pane, held files, screen and resolved name")
    func processesDecode() throws {
        let processes = try fixture().processes
        #expect(processes.map(\.comm) == ["claude", "codex", "bearcode", "agy"])

        let claude = processes[0]
        #expect(claude.ppid == 4000)
        #expect(claude.tty == "pts/1")
        #expect(claude.args == "claude --resume")
        #expect(claude.pane == RemotePane(socket: "/tmp/tmux-1000/default", id: "%3"))
        #expect(claude.open.count == 1)
        #expect(!claude.openFailed)
        #expect(claude.screen == nil)

        let codex = processes[1]
        #expect(codex.tty == "")
        #expect(codex.pane == nil)

        // Held files that could not be read are unknown, not empty.
        #expect(processes[2].openFailed)
        #expect(processes[2].open.isEmpty)

        #expect(processes[3].screen?.contains("> 1. Approve") == true)
    }

    @Test("a failed ps decodes as failed, never as no agents")
    func processesFailedDecodes() throws {
        let json = """
        {"ok":true,"protocol":3,"stream":"s","hostname":"h","system":"Darwin","now":0,
         "homes":[],"files":[],"dirs":[],"omitted":[],"warnings":["ps exited 1"],
         "processes":[],"processes_failed":true}
        """
        let snapshot = try RemoteSnapshot.decode(Data(json.utf8))
        #expect(snapshot.processesFailed)
        #expect(snapshot.processes.isEmpty)
    }

    @Test("a chunk that is not valid base64 fails the decode rather than writing garbage")
    func badBase64Throws() {
        let json = """
        {"ok":true,"protocol":3,"stream":"s","hostname":"h","system":"Linux","now":0,
         "homes":[],"dirs":[],"omitted":[],"warnings":[],"processes":[],"processes_failed":false,
         "files":[{"path":"/home/u/x","size":3,"mtime":0,"created":null,"reset":true,
                   "chunks":[[0,"!!not base64!!"]]}]}
        """
        #expect(throws: (any Error).self) { try RemoteSnapshot.decode(Data(json.utf8)) }
    }

    @Test("a file with a negative size fails the decode")
    func negativeSizeThrows() {
        let json = """
        {"ok":true,"protocol":3,"stream":"s","hostname":"h","system":"Linux","now":0,
         "homes":[],"dirs":[],"omitted":[],"warnings":[],"processes":[],"processes_failed":false,
         "files":[{"path":"/home/u/x","size":-1,"mtime":0,"created":null,"reset":true,"chunks":[]}]}
        """
        #expect(throws: (any Error).self) { try RemoteSnapshot.decode(Data(json.utf8)) }
    }

    @Test("a chunk with a negative offset fails the decode")
    func negativeOffsetThrows() {
        let json = """
        {"ok":true,"protocol":3,"stream":"s","hostname":"h","system":"Linux","now":0,
         "homes":[],"dirs":[],"omitted":[],"warnings":[],"processes":[],"processes_failed":false,
         "files":[{"path":"/home/u/x","size":3,"mtime":0,"created":null,"reset":true,
                   "chunks":[[-1,"YWJj"]]}]}
        """
        #expect(throws: (any Error).self) { try RemoteSnapshot.decode(Data(json.utf8)) }
    }

    @Test("a lone surrogate escape fails the whole decode, which is why the helper never sends one")
    func loneSurrogateFailsTheDecode() throws {
        func json(_ cwd: String) -> String {
            """
            {"ok":true,"protocol":3,"stream":"s","hostname":"h","system":"Linux","now":0,
             "homes":[],"files":[],"dirs":[],"omitted":[],"warnings":[],"processes_failed":false,
             "processes":[{"pid":1,"ppid":0,"user":"u","comm":"claude","args":"claude",
                           "cwd":"\(cwd)","tty":"","pane":null,"open":[]}]}
            """
        }
        #expect(throws: (any Error).self) { try RemoteSnapshot.decode(Data(json(#"/home/u/\udcff"#).utf8)) }
        // What the helper sends instead: the replacement character.
        let snapshot = try RemoteSnapshot.decode(Data(json(#"/home/u/\ufffd"#).utf8))
        #expect(snapshot.processes.first?.cwd == "/home/u/\u{FFFD}")
    }

    // MARK: Size limits

    private static let tiny = RemoteSnapshot.Limits(lineBytes: 4096, records: 4, chunkBytes: 8)

    private func isTooLarge(_ error: any Error) -> Bool {
        if case RemoteSnapshotError.tooLarge = error { return true }
        return false
    }

    @Test("a line over the ceiling is refused before anything decodes it")
    func oversizedLineIsRefusedUndecoded() {
        // Not JSON at all, so only a check made before decoding can name
        // the size as the reason.
        let line = Data(repeating: UInt8(ascii: "["), count: 4097)
        #expect(throws: (any Error).self) { try RemoteSnapshot.decode(line, limits: Self.tiny) }
        do {
            _ = try RemoteSnapshot.decode(line, limits: Self.tiny)
        } catch {
            #expect(isTooLarge(error))
        }
    }

    @Test("a snapshot with more records than the limit is refused")
    func tooManyRecordsIsRefused() {
        let dirs = (0..<5).map { #"{"path":"/home/u/d\#($0)","mtime":0,"created":null}"# }
        let json = """
        {"ok":true,"protocol":3,"stream":"s","hostname":"h","system":"Linux","now":0,
         "homes":[],"files":[],"omitted":[],"warnings":[],"processes":[],"processes_failed":false,
         "dirs":[\(dirs.joined(separator: ","))]}
        """
        do {
            _ = try RemoteSnapshot.decode(Data(json.utf8), limits: Self.tiny)
            Issue.record("five records must not pass a limit of four")
        } catch {
            #expect(isTooLarge(error))
        }
    }

    @Test("a snapshot whose chunks hold more bytes than the limit is refused")
    func tooManyChunkBytesIsRefused() {
        // "YWJjZGVmZ2hp" is nine bytes, one over the limit of eight.
        let json = """
        {"ok":true,"protocol":3,"stream":"s","hostname":"h","system":"Linux","now":0,
         "homes":[],"dirs":[],"omitted":[],"warnings":[],"processes":[],"processes_failed":false,
         "files":[{"path":"/home/u/x","size":9,"mtime":0,"created":null,"reset":true,
                   "chunks":[[0,"YWJjZGVmZ2hp"]]}]}
        """
        do {
            _ = try RemoteSnapshot.decode(Data(json.utf8), limits: Self.tiny)
            Issue.record("nine chunk bytes must not pass a limit of eight")
        } catch {
            #expect(isTooLarge(error))
        }
    }

    @Test("the standard limits leave room for an honest snapshot")
    func standardLimitsFitAnHonestSnapshot() throws {
        let limits = RemoteSnapshot.Limits.standard
        // Base64 inflates by four thirds, so the chunk budget must fit
        // inside the line ceiling, and both must hold a helper's 16 MB
        // whole-file ceiling several times over.
        #expect(limits.chunkBytes * 4 / 3 <= limits.lineBytes)
        #expect(limits.chunkBytes >= 8 * 16 * 1024 * 1024)
        _ = try fixture()
    }
}

/// Anchors `Bundle(for:)` to the test bundle so fixtures resolve.
private final class BundleMarker {}
