import SwiftUI
import Observation

@Observable
@MainActor
final class RecordingsViewModel {
    private(set) var recordings: [JellyfinItem] = []
    private(set) var timers: [LiveTvTimer] = []
    private(set) var seriesTimers: [LiveTvSeriesTimer] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let liveTvService: JellyfinLiveTvServiceProtocol
    private let itemService: JellyfinItemServiceProtocol
    private let userID: String

    init(liveTvService: JellyfinLiveTvServiceProtocol,
         itemService: JellyfinItemServiceProtocol,
         userID: String) {
        self.liveTvService = liveTvService
        self.itemService = itemService
        self.userID = userID
    }

    /// Fetch all three sections concurrently. Errors degrade per
    /// section (an empty timers list is indistinguishable from a failed
    /// one by design; recordings failure surfaces the alert).
    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let recs = liveTvService.getRecordings(userID: userID)
        async let tims = liveTvService.getTimers()
        async let series = liveTvService.getSeriesTimers()
        do { recordings = try await recs } catch { errorMessage = error.localizedDescription }
        timers = (try? await tims) ?? []
        seriesTimers = (try? await series) ?? []
        // Upcoming first; spawned-but-cancelled entries are server-filtered.
        timers.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    func deleteRecording(_ item: JellyfinItem) async {
        do {
            try await itemService.deleteItem(itemID: item.id)
            recordings.removeAll { $0.id == item.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelTimer(_ timer: LiveTvTimer) async {
        do {
            try await liveTvService.cancelTimer(timerID: timer.id)
            timers.removeAll { $0.id == timer.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelSeriesTimer(_ timer: LiveTvSeriesTimer) async {
        do {
            try await liveTvService.cancelSeriesTimer(timerID: timer.id)
            seriesTimers.removeAll { $0.id == timer.id }
            // Spawned episode timers die with the rule.
            timers.removeAll { $0.seriesTimerId == timer.id }
        } catch { errorMessage = error.localizedDescription }
    }
}
