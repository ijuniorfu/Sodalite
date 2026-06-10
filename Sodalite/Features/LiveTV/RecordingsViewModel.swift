import SwiftUI
import Observation

@Observable
@MainActor
final class RecordingsViewModel {
    private(set) var recordings: [JellyfinItem] = []
    private(set) var timers: [LiveTvTimer] = []
    private(set) var seriesTimers: [LiveTvSeriesTimer] = []
    /// Ids of recordings the server reports as currently being written
    /// (IsInProgress=true filter). Drives the "Läuft" badge; item fields
    /// cannot (BaseItemDto.Status stays empty on recording items).
    private(set) var inProgressIDs: Set<String> = []
    private(set) var isLoading = false
    var errorMessage: String?

    func isInProgress(_ item: JellyfinItem) -> Bool {
        inProgressIDs.contains(item.id)
    }

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
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let recs = liveTvService.getRecordings(userID: userID, isInProgress: nil)
        // Active recordings come from the IsInProgress server filter, the
        // same way jellyfin-web builds its "Active Recordings" row.
        async let active = liveTvService.getRecordings(userID: userID, isInProgress: true)
        async let tims = liveTvService.getTimers()
        async let series = liveTvService.getSeriesTimers()
        do { recordings = try await recs } catch { errorMessage = error.localizedDescription }
        inProgressIDs = Set(((try? await active) ?? []).map(\.id))
        // The server returns cancelled series-spawned entries; drop them so
        // only actionable (pending/scheduled) timers appear. Mirrors
        // EPGGuideViewModel.reconcileTimers which applies the same guard.
        timers = ((try? await tims) ?? []).filter { $0.status != "Cancelled" }
        seriesTimers = (try? await series) ?? []
        // Upcoming first.
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
