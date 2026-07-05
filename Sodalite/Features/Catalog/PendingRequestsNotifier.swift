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

    /// Fire a local notification announcing `count` requests awaiting approval. Plural handled by the
    /// xcstrings variations of `catalog.notify.pending.body`.
    static func notifyPendingIncrease(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "catalog.notify.pending.title", defaultValue: "Requests awaiting approval")
        content.body = String(
            format: String(localized: "catalog.notify.pending.body", defaultValue: "%d requests are waiting for approval."),
            count
        )
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
