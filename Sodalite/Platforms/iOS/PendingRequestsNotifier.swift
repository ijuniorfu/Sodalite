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

    /// Install the delegate so notifications also present as a banner while the app is foregrounded
    /// (iOS suppresses foreground notifications by default).
    static func configureForegroundPresentation() {
        UNUserNotificationCenter.current().delegate = foregroundDelegate
    }

    private static let foregroundDelegate = ForegroundPresentationDelegate()
}

/// Presents notifications as banners even when the app is in the foreground.
private final class ForegroundPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }
}

/// Orchestrates a monitor refresh with its notification side effects: keeps the app-icon badge in
/// sync with the live count and fires a local notification when the count rose since the last-seen
/// value. Foreground and background both funnel through here so the behavior is identical.
enum PendingRequestsSync {
    @MainActor
    static func refreshAndSync(
        monitor: PendingRequestsMonitor,
        preferences: SeerrNotificationPreferences
    ) async {
        await monitor.refresh()
        // Notifications off: the tab badge (monitor) still updated above; leave the app-icon badge alone.
        guard preferences.notifyPendingRequests, let count = monitor.pendingApprovalCount else { return }
        if PendingRequestsMonitor.shouldNotify(current: count, lastSeen: preferences.lastSeenPendingCount) {
            await PendingRequestsNotifier.notifyPendingIncrease(count: count)
        }
        await PendingRequestsNotifier.setBadgeCount(count)
        preferences.lastSeenPendingCount = count
    }
}
