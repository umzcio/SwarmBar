import Foundation
import Observation

/// Checks GitHub releases for a newer version. There is no update channel
/// until the repo is published with releases; until then the check fails
/// honestly instead of pretending to be current.
@MainActor
@Observable
final class UpdateChecker {
    /// Update this when the repo gets its public home.
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
                      let tag = json["tag_name"] as? String,
                      let page = (json["html_url"] as? String).flatMap(URL.init(string:))
                else {
                    status = .failed("No update channel yet")
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                status = Self.isNewer(latest, than: Self.currentVersion)
                    ? .available(version: latest, url: page)
                    : .upToDate
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
}
