import AppKit
import Foundation
import UserNotifications

/// Posts macOS notifications when a session starts needing the user.
///
/// Authorization is requested once at launch rather than lazily on the
/// first post. Lazily was wrong in a way that hid itself: the request
/// would land at whatever moment an agent first needed something, which
/// is precisely when the user is not looking at SwarmBar, and if macOS
/// refused there was nothing anywhere to say so.
enum AgentNotifier {
    /// Whether macOS has actually granted permission. Nil until the first
    /// answer arrives. The Settings toggles decide what SwarmBar *wants*
    /// to send; this is whether it is allowed to send anything at all, and
    /// the two are easy to confuse when three switches are on and nothing
    /// ever appears.
    @MainActor private(set) static var authorization: Result<Bool, Error>?

    static func prepare() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                Task { @MainActor in
                    authorization = error.map(Result.failure) ?? .success(granted)
                }
                guard !granted else { return }
                // Do not discard this. A refusal is the difference between
                // "no agent needed you" and "every alert was dropped", and
                // discarding it is why that went unnoticed. Do Not Disturb
                // being on is one way to get here: the prompt cannot be
                // shown, so the request fails rather than pending.
                NSLog("SwarmBar: notifications not authorized: \(String(describing: error))")
            }
    }

    /// Whether macOS will actually deliver anything right now. Asked fresh
    /// rather than remembered, since permission can be revoked in System
    /// Settings while the app runs.
    static func isAllowed() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func post(title: String, body: String, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            else {
                NSLog("SwarmBar: dropping notification, status \(settings.authorizationStatus.rawValue)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
