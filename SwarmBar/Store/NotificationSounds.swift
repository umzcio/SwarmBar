import AppKit
import Foundation

/// What a notification should sound like. The choice is kept apart from
/// UserNotifications so that the rules can be tested without posting one.
enum AlertSound: Equatable, Sendable {
    case silent
    case standard
    case file(String)
}

/// The sounds Settings offers, and which one an alert plays.
///
/// Custom sounds live in ~/Library/Sounds because that is where macOS itself
/// looks for a named notification sound when an app is not sandboxed, so a
/// file added there needs nothing from SwarmBar beyond being listed.
enum NotificationSounds {
    enum Kind: Sendable {
        case approval
        case waiting

        var defaultsKey: String {
            switch self {
            case .approval: "approvalSound"
            case .waiting: "waitingSound"
            }
        }
    }

    struct Option: Equatable, Identifiable, Sendable {
        let url: URL
        var name: String { url.deletingPathExtension().lastPathComponent }
        var id: String { name }
    }

    /// The containers and encodings macOS documents for notification sounds.
    /// An MP3 or a Voice Memos M4A is left out on purpose: it would be listed
    /// as a choice and then alert with some other sound.
    private static let playableExtensions: Set<String> = ["aiff", "aif", "wav", "caf"]

    static func options(user: [URL], system: [URL]) -> [Option] {
        var byName: [String: Option] = [:]
        // User files second, so a user's "Glass" replaces the system one.
        for url in system + user {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."),
                  playableExtensions.contains(url.pathExtension.lowercased())
            else { continue }
            let option = Option(url: url)
            byName[option.name] = option
        }
        return byName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// A chosen sound that is no longer installed falls back to the standard
    /// sound, never to silence: a missed approval leaves an agent stuck.
    static func alertSound(enabled: Bool, chosen: String?, options: [Option]) -> AlertSound {
        guard enabled else { return .silent }
        guard let option = options.first(where: { $0.name == chosen }) else { return .standard }
        return .file(option.url.lastPathComponent)
    }

    // MARK: - This Mac

    static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Sounds", directoryHint: .isDirectory)
    }

    static func installedOptions() -> [Option] {
        options(
            user: files(in: userFolder),
            system: files(in: URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)))
    }

    /// Read at each alert rather than cached, so a sound added or removed
    /// while SwarmBar runs takes effect on the next one.
    static func current(for kind: Kind, defaults: UserDefaults = .standard) -> AlertSound {
        alertSound(
            enabled: (defaults.object(forKey: "notifySound") as? Bool) ?? true,
            chosen: defaults.string(forKey: kind.defaultsKey),
            options: installedOptions())
    }

    private static func files(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// Held so a new preview can cut off the last one instead of overlapping.
    @MainActor private static var previewing: NSSound?

    @MainActor
    static func preview(_ option: Option) {
        previewing?.stop()
        previewing = NSSound(contentsOf: option.url, byReference: true)
        previewing?.play()
    }

    /// The folder is hidden in Finder and may not exist yet, so Settings
    /// offers a way in rather than only naming the path.
    @MainActor
    static func openUserFolder() {
        try? FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(userFolder)
    }
}
