#if os(iOS)
import Foundation
import UserNotifications

/// iOS-only wrapper for the local-notification + app-icon-badge side of the pending-requests feature.
enum PendingRequestsNotifier {
    /// Ask the user for notification permission. Returns whether it was granted.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Fire a local notification that new requests await approval. The exact count is carried by the
    /// app-icon badge, so the text stays count-agnostic (no per-locale plural handling needed).
    static func notifyPendingIncrease(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "catalog.notify.pending.title", defaultValue: "Requests awaiting approval")
        content.body = String(localized: "catalog.notify.pending.body", defaultValue: "New requests are waiting for your approval.")
        content.badge = NSNumber(value: count)
        let request = UNNotificationRequest(
            identifier: "seerr.pendingRequests",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func setBadgeCount(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
#endif
