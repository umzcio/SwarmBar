import Foundation
import Testing
@testable import SwarmBar

@Suite struct SSHConfigTests {
    private let base = URL(fileURLWithPath: "/home/u/.ssh", isDirectory: true)

    private func aliases(
        _ text: String,
        files: [String: String] = [:],
        listing: [String: [String]] = [:]
    ) -> [String] {
        SSHConfigParser.aliases(
            in: text, baseDirectory: base,
            home: URL(fileURLWithPath: "/home/u", isDirectory: true),
            read: { files[$0.path] },
            list: { listing[$0] ?? [] })
    }

    @Test func parsesMultipleNamesAndSkipsPatterns() {
        #expect(aliases("Host alpha beta *.corp !gamma") == ["alpha", "beta"])
    }

    @Test func followsIncludeRelativeToSSHDir() {
        let files = ["/home/u/.ssh/extra": "Host beta\n"]
        #expect(aliases("Host alpha\nInclude extra\n", files: files) == ["alpha", "beta"])
    }

    @Test func followsGlobIncludeInListedOrder() {
        let files = [
            "/home/u/.ssh/conf.d/a": "Host beta\n",
            "/home/u/.ssh/conf.d/b": "Host gamma\n",
        ]
        let listing = ["/home/u/.ssh/conf.d/*": ["/home/u/.ssh/conf.d/a", "/home/u/.ssh/conf.d/b"]]
        #expect(aliases("Include conf.d/*\nHost alpha\n", files: files, listing: listing)
            == ["beta", "gamma", "alpha"])
    }

    @Test func tildeExpandsToHome() {
        let files = ["/home/u/more": "Host beta\n"]
        #expect(aliases("Include ~/more\n", files: files) == ["beta"])
    }

    @Test func includeDepthIsBounded() {
        let files = ["/home/u/.ssh/loop": "Host alpha\nInclude loop\n"]
        #expect(aliases("Include loop\n", files: files) == ["alpha"])
    }

    @Test func keywordsAreCaseInsensitive() {
        #expect(aliases("host alpha\nHOST=beta\nHost = \"devbox\"\n") == ["alpha", "beta", "devbox"])
    }

    @Test func matchBlocksAreSkipped() {
        let text = """
        Host alpha
        Match host beta
          Include nothere
        Host gamma
        """
        #expect(aliases(text) == ["alpha", "gamma"])
    }

    @Test func duplicatesKeepFirstSeenOrder() {
        #expect(aliases("Host alpha beta\nHost beta alpha devbox\n") == ["alpha", "beta", "devbox"])
    }

    @Test func gitHostsAndGitUserAreSkipped() {
        let resolved = [
            "alpha": SSHResolved(hostname: "github.com", user: "git", port: 22),
            "beta": SSHResolved(hostname: "git.example.test", user: "git", port: 22),
            "gamma": SSHResolved(hostname: "10.0.0.5", user: "u", port: 22),
        ]
        #expect(HostCandidates.filter(["alpha", "beta", "gamma"], resolved: resolved) == ["gamma"])
    }

    @Test func sameHostnameAndPortCollapseToFirstAlias() {
        let resolved = [
            "alpha": SSHResolved(hostname: "10.0.0.5", user: "u", port: 22),
            "beta": SSHResolved(hostname: "10.0.0.5", user: "u", port: 22),
            "devbox": SSHResolved(hostname: "10.0.0.5", user: "u", port: 2222),
        ]
        #expect(HostCandidates.filter(["alpha", "beta", "devbox"], resolved: resolved)
            == ["alpha", "devbox"])
    }

    @Test func unresolvedAliasesAreKept() {
        #expect(HostCandidates.filter(["alpha"], resolved: [:]) == ["alpha"])
    }

    private struct Result { let host: String?; let ok: Bool; let tag: Int }

    @Test func collapseKeepsTheConnectedOneForEachHostname() {
        let input = [
            Result(host: "h1", ok: false, tag: 1),
            Result(host: "h1", ok: true, tag: 2),
            Result(host: "h2", ok: true, tag: 3),
            Result(host: "h2", ok: true, tag: 4),
            Result(host: nil, ok: false, tag: 5),
            Result(host: nil, ok: false, tag: 6),
        ]
        let out = HostCandidates.collapse(input, hostname: { $0.host }, connected: { $0.ok })
        #expect(out.map(\.tag) == [2, 3, 5, 6])
    }

    @Test func parsesSSHGOutput() {
        let out = "host alpha\nuser deploy\nhostname 10.0.0.5\nport 2222\nidentityfile ~/.ssh/id\n"
        #expect(SSHResolved.parse(out) == SSHResolved(hostname: "10.0.0.5", user: "deploy", port: 2222))
        #expect(SSHResolved.parse("user deploy\n") == nil)
    }
}
