#if os(iOS)
import Foundation
import BackgroundTasks

/// iOS-only BGAppRefreshTask wrapper: polls the pending-approval count in the background and fires a
/// local notification (via PendingRequestsNotifier) when it rose since the last observation.
enum PendingRequestsBackgroundRefresh {
    static let identifier = "de.superuser404.Sodalite.pendingRequestsRefresh"
    /// iOS throttles refresh anyway; ask for no sooner than ~30 min.
    private static let earliestInterval: TimeInterval = 30 * 60

    /// Register the task handler once at launch. `handle` runs the whole background check on the main
    /// actor (fetch, notify-on-increase, set app-icon badge, persist baseline) and returns whether
    /// notifications are still enabled, so the cycle keeps rescheduling only while opted in.
    static func register(handle: @escaping @MainActor @Sendable () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // The launch handler runs on a background queue; hop to the main actor for all state + SDK calls.
            nonisolated(unsafe) let bgTask = task
            let work = Task { @MainActor in
                let keepGoing = await handle()
                if keepGoing { schedule() }
                bgTask.setTaskCompleted(success: true)
            }
            bgTask.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
#endif
