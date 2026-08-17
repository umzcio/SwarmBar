import Foundation
import Testing
@testable import SwarmBar

@Suite("Remote snapshot decoding")
struct RemoteSnapshotTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle(for: BundleMarker.self)
            .url(forResource: "remote-snapshot-umzcaio", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test("decodes the live fixture captured from umzcaio")
    func decodesFixture() throws {
        let snapshot = try RemoteSnapshot.decode(fixture())
        #expect(snapshot.ok)
        #expect(snapshot.system == "Linux")
        #expect(snapshot.sessions.count == 4)

        let sessions = RemoteSnapshot.sessions(from: snapshot, host: "umzcaio", now: .now)
        #expect(sessions.count == 4)
    }

    @Test("no backup root survives into the snapshot")
    func excludesBackupRoots() throws {
        let snapshot = try RemoteSnapshot.decode(fixture())
        #expect(!snapshot.roots.contains { $0.lowercased().contains("backup") })
    }

    @Test("sessions carry the host and derive stable ids from host plus path")
    func sessionsCarryHost() throws {
        let snapshot = try RemoteSnapshot.decode(fixture())
        let sessions = RemoteSnapshot.sessions(from: snapshot, host: "umzcaio", now: .now)
        #expect(!sessions.isEmpty)
        #expect(sessions.allSatisfy { $0.host == "umzcaio" })
        #expect(sessions.allSatisfy { $0.tool == .claudeCode })

        let first = try #require(snapshot.sessions.first)
        let expected = StableID.uuid(for: "umzcaio:" + first.path)
        #expect(sessions.contains { $0.id == expected })
    }

    @Test("the same path on two hosts yields two distinct sessions")
    func hostScopedIdentity() throws {
        let snapshot = try RemoteSnapshot.decode(fixture())
        let a = RemoteSnapshot.sessions(from: snapshot, host: "umzcaio", now: .now)
        let b = RemoteSnapshot.sessions(from: snapshot, host: "umzflash", now: .now)
        #expect(Set(a.map(\.id)).isDisjoint(with: Set(b.map(\.id))))
    }

    @Test("a session whose cwd matches a live agent process is marked alive")
    func livenessFromCwd() throws {
        let json = """
        {"ok":true,"protocol":1,"hostname":"h","system":"Linux","now":0,
         "roots":["/root/.claude/projects"],
         "sessions":[{"tool":"claudeCode","path":"/root/.claude/projects/-projects-AIF/\
        11111111-1111-1111-1111-111111111111.jsonl","root":"/root/.claude/projects",
         "project_dir":"-projects-AIF","mtime":0,"size":10,
         "tail":"{\\"type\\":\\"user\\",\\"cwd\\":\\"/projects/AIF\\"}"}],
         "processes":[{"pid":1,"user":"root","comm":"claude","cwd":"/projects/AIF"}],
         "processes_failed":false,"warnings":[]}
        """
        let snapshot = try RemoteSnapshot.decode(Data(json.utf8))
        let sessions = RemoteSnapshot.sessions(from: snapshot, host: "h", now: .now)
        #expect(sessions.count == 1)
        #expect(sessions[0].processAlive)
    }

    @Test("liveness is never claimed when ps itself failed, even with a matching cwd present")
    func noLivenessWhenPsFailed() throws {
        // The helper's wire protocol always sends an empty `processes` array
        // alongside `processes_failed: true`, but the decoder must not rely
        // on that invariant holding. This payload deliberately violates it,
        // shipping a "claude" process whose cwd exactly matches the
        // session's cwd, so that only the processesFailed gate (not an
        // incidentally empty processes list) can keep processAlive false.
        let json = """
        {"ok":true,"protocol":1,"hostname":"h","system":"Darwin","now":0,
         "roots":[],
         "sessions":[{"tool":"claudeCode","path":"/Users/z/.claude/projects/-p/\
        22222222-2222-2222-2222-222222222222.jsonl","root":"/Users/z/.claude/projects",
         "project_dir":"-p","mtime":0,"size":10,
         "tail":"{\\"type\\":\\"user\\",\\"cwd\\":\\"/p\\"}"}],
         "processes":[{"pid":1,"user":"z","comm":"claude","cwd":"/p"}],
         "processes_failed":true,"warnings":["ps exited 1"]}
        """
        let snapshot = try RemoteSnapshot.decode(Data(json.utf8))
        let sessions = RemoteSnapshot.sessions(from: snapshot, host: "h", now: .now)
        #expect(sessions.count == 1)
        #expect(!sessions[0].processAlive)
        #expect(snapshot.processesFailed)
    }
}

/// Anchors `Bundle(for:)` to the test bundle so fixtures resolve.
private final class BundleMarker {}
