import Foundation
import UserNotifications

/// Posts macOS notifications when a session starts needing the user.
/// Authorization is requested lazily on the first post; the settings
/// toggles decide what gets through before this is ever called.
enum AgentNotifier {
    static func post(title: String, body: String, sound: Bool) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
