import Foundation
import Observation
import Sparkle

/// Checking, downloading, installing and relaunching, via Sparkle.
///
/// The hand-rolled checker this replaces could only open the releases
/// page, so every update was a manual download, unzip and drag. Self
/// updating is the one place in this app where a dependency earns its
/// keep: it replaces the running app with a file fetched over the
/// network, and the EdDSA signature check that makes that safe is exactly
/// the part worth not writing twice. The public key lives in Info.plist
/// as SUPublicEDKey; the private half never leaves the release machine.
@MainActor
@Observable
final class SwarmUpdater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController

    /// Sparkle refuses a second check while one is running, so the button
    /// follows its state rather than tracking its own.
    private(set) var canCheckForUpdates = true

    init() {
        // startingUpdater: true begins the scheduled background check too,
        // so a user who never opens Settings still hears about a release.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        withObservationTracking {
            _ = controller.updater.canCheckForUpdates
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncCanCheck() }
        }
        syncCanCheck()
    }

    private func syncCanCheck() {
        canCheckForUpdates = controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
        syncCanCheck()
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
