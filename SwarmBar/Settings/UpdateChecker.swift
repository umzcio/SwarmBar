import Foundation
import Observation

/// Checks GitHub releases for a newer version. There is no update channel
/// until the repo is published with releases; until then the check fails
/// honestly instead of pretending to be current.
@MainActor
@Observable
final class UpdateChecker {
    /// The release channel. This name must be registered by the project
    /// owner before shipping a build that polls it: whoever owns it
    /// controls the version string and the release link this app shows.
    static let repo = "umzcio/SwarmBar"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    private(set) var status: Status = .idle

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    func check() {
        status = .checking
        Task {
            do {
                let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String
                else {
                    status = .failed("No update channel yet")
                    return
                }
                guard let latest = Self.normalizedVersion(tag) else {
                    status = .failed("No update channel yet")
                    return
                }
                guard Self.isNewer(latest, than: Self.currentVersion) else {
                    status = .upToDate
                    return
                }
                let link = (json["html_url"] as? String)
                    .flatMap { Self.trustedReleaseURL($0) }
                    ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!
                status = .available(version: latest, url: link)
            } catch {
                status = .failed("Couldn't reach GitHub")
            }
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A release link is only trusted when it is an https github.com URL
    /// under the configured repository. Anything else (another host, another
    /// scheme, another repo) is treated as no link at all, because the value
    /// comes from a response body and is handed to NSWorkspace, which
    /// dispatches non-https schemes to local handlers.
    static func trustedReleaseURL(_ raw: String, repo: String = UpdateChecker.repo) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.path.hasPrefix("/\(repo)/")
        else { return nil }
        return url
    }

    /// Release tags are expected to look like 1.2.3 or v1.2.3. Anything else
    /// is not rendered, since the value is displayed in the About card.
    static func normalizedVersion(_ tag: String) -> String? {
        let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return nil }
        let parts = trimmed.split(separator: ".")
        guard (1...4).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return trimmed
    }
}
