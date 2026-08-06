import Foundation
import Observation

/// Record timers and channel favorites, optimistically applied and reconciled against the server.
/// Shared by the guide, the Übersicht rows and the iPhone channel list: all three show the same
/// dots and the same button captions, so the overlay cannot live inside one of them.
@Observable
@MainActor
final class LiveTimerStore {

    /// Favorited channel IDs. Seeded from each page's server-side IsFavorite, updated
    /// optimistically; EnableFavoriteSorting floats them to the top on the next fresh load.
    private(set) var favoriteChannelIDs: Set<String> = []

    /// programID -> (timerId, seriesTimerId). A nil member means no such timer.
    private(set) var timerState: [String: (timerId: String?, seriesTimerId: String?)] = [:]

    /// Bumped on every timerState change; the grid observes this because a dictionary of tuples is
    /// not cheaply diffable.
    private(set) var timerStateVersion = 0

    /// Transient record-toggle error for the guide's alert.
    var recordingError: String?

    /// Sentinel for a create still in flight (the server assigns the real id; `reconcileTimers`
    /// replaces it). Toggles no-op on it so a double press cannot DELETE /LiveTv/Timers/pending.
    private static let pendingTimerID = "pending"

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String

    init(service: JellyfinLiveTvServiceProtocol, userID: String) {
        self.service = service
        self.userID = userID
    }

    // MARK: - Seeding

    func seedFavorites(from channels: [JellyfinChannel]) {
        for channel in channels where channel.isFavorite {
            favoriteChannelIDs.insert(channel.id)
        }
    }

    func seedTimers(from programs: [JellyfinProgram]) {
        var touched = false
        for program in programs where program.timerId != nil || program.seriesTimerId != nil {
            timerState[program.id] = (program.timerId, program.seriesTimerId)
            touched = true
        }
        if touched { timerStateVersion += 1 }
    }

    // MARK: - Accessors

    func isFavorite(_ channelID: String) -> Bool { favoriteChannelIDs.contains(channelID) }

    func hasTimer(programID: String) -> Bool {
        let state = timerState[programID]
        return state?.timerId != nil || state?.seriesTimerId != nil
    }

    /// The overlay entry when one exists (it reflects local toggles), else the program's server
    /// snapshot. After a cancel the overlay holds (nil, ...) and must shadow the stale snapshot so
    /// the dead timer id is not resurrected.
    func effectiveTimerState(for program: JellyfinProgram) -> (timerId: String?, seriesTimerId: String?) {
        timerState[program.id] ?? (program.timerId, program.seriesTimerId)
    }

    // MARK: - Favorites

    /// Optimistically flip the local set, persist, roll back on failure. Re-sorting happens on the
    /// next fresh load via EnableFavoriteSorting, not live, so scroll and focus stay put.
    func toggleFavorite(channelID: String) {
        let wasFavorite = favoriteChannelIDs.contains(channelID)
        if wasFavorite { favoriteChannelIDs.remove(channelID) } else { favoriteChannelIDs.insert(channelID) }
        let target = !wasFavorite
        Task {
            do {
                try await service.setFavorite(userID: userID, channelID: channelID, isFavorite: target)
            } catch {
                if target { favoriteChannelIDs.remove(channelID) } else { favoriteChannelIDs.insert(channelID) }
            }
        }
    }

    // MARK: - Record toggles

    func toggleRecord(program: JellyfinProgram) {
        let old = timerState[program.id]
        let effective = effectiveTimerState(for: program)
        if let timerID = effective.timerId {
            if timerID == Self.pendingTimerID { return }
            // Preserve the EFFECTIVE series id, not the overlay's: a series-spawned timer with no
            // overlay entry has old=nil, so (nil, old?.seriesTimerId) would erase a live series rule
            // and let the popover offer "Record Series" again, creating a server duplicate.
            timerState[program.id] = (nil, effective.seriesTimerId)
            timerStateVersion += 1
            Task {
                do { try await self.service.cancelTimer(timerID: timerID) }
                catch { self.rollback(programID: program.id, to: old, error: error) }
            }
        } else {
            timerState[program.id] = (Self.pendingTimerID, effective.seriesTimerId)
            timerStateVersion += 1
            Task {
                do {
                    try await self.service.createTimer(programID: program.id)
                    await self.reconcileTimers()
                } catch { self.rollback(programID: program.id, to: old, error: error) }
            }
        }
    }

    func toggleSeriesRecord(program: JellyfinProgram) {
        let old = timerState[program.id]
        let effective = effectiveTimerState(for: program)
        if let seriesID = effective.seriesTimerId {
            if seriesID == Self.pendingTimerID { return }
            // effective.timerId, not old?.timerId: see toggleRecord.
            timerState[program.id] = (effective.timerId, nil)
            timerStateVersion += 1
            Task {
                do {
                    try await self.service.cancelSeriesTimer(timerID: seriesID)
                    // The server cancels the rule's spawned episode timers too; clear every overlay
                    // entry tied to this series so dead dots and buttons vanish.
                    self.clearSeriesOverlay(seriesTimerID: seriesID)
                } catch { self.rollback(programID: program.id, to: old, error: error) }
            }
        } else {
            timerState[program.id] = (effective.timerId, Self.pendingTimerID)
            timerStateVersion += 1
            Task {
                do {
                    try await self.service.createSeriesTimer(programID: program.id)
                    await self.reconcileTimers()
                } catch { self.rollback(programID: program.id, to: old, error: error) }
            }
        }
    }

    private func clearSeriesOverlay(seriesTimerID: String) {
        for (programID, state) in timerState where state.seriesTimerId == seriesTimerID {
            timerState[programID] = (nil, nil)
        }
        timerStateVersion += 1
    }

    private func rollback(programID: String,
                          to old: (timerId: String?, seriesTimerId: String?)?,
                          error: Error) {
        timerState[programID] = old
        timerStateVersion += 1
        recordingError = error.localizedDescription
    }

    /// After a create, replace sentinel ids with the server's real ones and pick up series-spawned timers.
    private func reconcileTimers() async {
        guard let timers = try? await service.getTimers() else { return }
        for timer in timers where timer.status != .cancelled {
            guard let programID = timer.programId else { continue }
            timerState[programID] = (timer.id, timer.seriesTimerId ?? timerState[programID]?.seriesTimerId)
        }
        // A create the server did not report back (a series rule that spawned no timer for this
        // exact program) must not leave the sentinel pinned, or both toggles no-op on it forever.
        for (programID, state) in timerState {
            let timerID = state.timerId == Self.pendingTimerID ? nil : state.timerId
            let seriesID = state.seriesTimerId == Self.pendingTimerID ? nil : state.seriesTimerId
            if timerID != state.timerId || seriesID != state.seriesTimerId {
                timerState[programID] = (timerID, seriesID)
            }
        }
        timerStateVersion += 1
    }

    /// Full sync on return from the Aufnahmen segment, where timers and rules can be cancelled
    /// outside this overlay. `knownPrograms` are the programs whose immutable server snapshot would
    /// otherwise resurrect a cancelled timer.
    func syncWithServer(knownPrograms: [JellyfinProgram]) async {
        async let timersTask = try? service.getTimers()
        async let seriesTask = try? service.getSeriesTimers()
        guard let timers = await timersTask else { return }
        let seriesTimers = await seriesTask

        let live = timers.filter { $0.status != .cancelled }
        let liveTimerIDs = Set(live.map(\.id))
        // Series-rule drops need the dedicated list: a rule between airings has no live timer and
        // would be wrongly dropped. On fetch failure, leave series state untouched.
        let seriesListAuthoritative = seriesTimers != nil
        let liveSeriesIDs = seriesTimers.map { Set($0.map(\.id)) } ?? []

        for timer in live {
            guard let programID = timer.programId else { continue }
            timerState[programID] = (timer.id, timer.seriesTimerId ?? timerState[programID]?.seriesTimerId)
        }
        for (programID, state) in timerState {
            var timerID = state.timerId
            var seriesID = state.seriesTimerId
            if let t = timerID, t != Self.pendingTimerID, !liveTimerIDs.contains(t) { timerID = nil }
            if seriesListAuthoritative, let s = seriesID, s != Self.pendingTimerID,
               !liveSeriesIDs.contains(s) { seriesID = nil }
            if timerID != state.timerId || seriesID != state.seriesTimerId {
                timerState[programID] = (timerID, seriesID)
            }
        }
        // Programs with ids only in the immutable snapshot need an explicit overriding entry to
        // shadow that snapshot in effectiveTimerState.
        for program in knownPrograms where timerState[program.id] == nil {
            let snapTimer = program.timerId
            let snapSeries = program.seriesTimerId
            guard snapTimer != nil || snapSeries != nil else { continue }
            let newTimer = snapTimer.flatMap { liveTimerIDs.contains($0) ? $0 : nil }
            let newSeries = seriesListAuthoritative
                ? snapSeries.flatMap { liveSeriesIDs.contains($0) ? $0 : nil }
                : snapSeries
            if newTimer != snapTimer || newSeries != snapSeries {
                timerState[program.id] = (newTimer, newSeries)
            }
        }
        timerStateVersion += 1
    }
}
