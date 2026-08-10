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

    /// What to do when the user clicks a banner. Set by the app to bring
    /// the session's terminal forward. Without a delegate installed, macOS
    /// has nowhere to deliver the click and a tap does nothing at all,
    /// which is how this shipped.
    @MainActor static var onClick: ((UUID) -> Void)?

    @MainActor private static let delegate = ClickDelegate()

    static func prepare() {
        Task { @MainActor in
            UNUserNotificationCenter.current().delegate = delegate
        }
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

    static func post(title: String, body: String, sound: Bool, sessionID: UUID? = nil) {
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
            // Which session this is about, so the click knows where to go.
            if let sessionID { content.userInfo = ["sessionID": sessionID.uuidString] }
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Receives banner clicks. Has to be an NSObject, and has to be installed
/// before the app finishes launching, which is why prepare() sets it.
///
/// Not actor-isolated: the delegate methods are called by the system off
/// the main actor, and the parameters are not Sendable, so the class stays
/// nonisolated and hops only for the part that touches app state.
private final class ClickDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["sessionID"] as? String
        completionHandler()
        guard let raw, let id = UUID(uuidString: raw) else { return }
        Task { @MainActor in AgentNotifier.onClick?(id) }
    }

    /// Show the banner even when SwarmBar is frontmost. It has no windows,
    /// so "frontmost" tells the user nothing, and suppressing it would drop
    /// the alert exactly when they are looking at the popover.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
