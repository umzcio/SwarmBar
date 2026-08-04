import Foundation
import Testing
@testable import SwarmBar

@MainActor
struct UpdateCheckerTests {
    @Test func acceptsAGenuineReleaseLink() {
        let url = UpdateChecker.trustedReleaseURL(
            "https://github.com/umzcio/SwarmBar/releases/tag/v1.2.0",
            repo: "umzcio/SwarmBar")
        #expect(url != nil)
    }

    @Test func rejectsAnotherHost() {
        #expect(UpdateChecker.trustedReleaseURL(
            "https://example.com/umzcio/SwarmBar/releases/tag/v1",
            repo: "umzcio/SwarmBar") == nil)
    }

    @Test func rejectsANonHttpsScheme() {
        #expect(UpdateChecker.trustedReleaseURL(
            "file:///Applications/Something.app",
            repo: "umzcio/SwarmBar") == nil)
        #expect(UpdateChecker.trustedReleaseURL(
            "ftp://github.com/umzcio/SwarmBar/releases",
            repo: "umzcio/SwarmBar") == nil)
    }

    @Test func rejectsAnotherRepository() {
        #expect(UpdateChecker.trustedReleaseURL(
            "https://github.com/someone/else/releases/tag/v9",
            repo: "umzcio/SwarmBar") == nil)
    }

    @Test func normalizesPlainVersions() {
        #expect(UpdateChecker.normalizedVersion("v1.2.3") == "1.2.3")
        #expect(UpdateChecker.normalizedVersion("0.1.0") == "0.1.0")
    }

    @Test func rejectsJunkVersions() {
        #expect(UpdateChecker.normalizedVersion("") == nil)
        #expect(UpdateChecker.normalizedVersion("click here to win") == nil)
        #expect(UpdateChecker.normalizedVersion("1.2.3-beta") == nil)
        #expect(UpdateChecker.normalizedVersion(String(repeating: "9", count: 40)) == nil)
    }

    @Test func versionComparisonStillWorks() {
        #expect(UpdateChecker.isNewer("1.2.0", than: "1.1.9"))
        #expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("0.9.0", than: "1.0.0"))
    }
}
