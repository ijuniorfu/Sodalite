import SwiftUI
import Observation

@Observable
@MainActor
final class EPGGuideViewModel {
    /// Horizontal scale, points per minute. 8 puts ~3.25h on screen; the previous 6 showed ~4.3h,
    /// squeezing program titles too hard to read.
    static let pointsPerMinute: CGFloat = 8
    static let rowHeight: CGFloat = 110
    static let channelColumnWidth: CGFloat = 360
    /// How far ahead of `now` the guide axis extends.
    static let windowHours: Int = 24

    private(set) var channels: [JellyfinChannel] = []
    /// channelID -> its programs, sorted by startDate.
    private(set) var programsByChannel: [String: [JellyfinProgram]] = [:]
    private(set) var isLoadingChannels = false
    private(set) var loadError: String?
    /// Favorited channel IDs. Seeded from each page's server-side IsFavorite, updated optimistically;
    /// server-side EnableFavoriteSorting floats them to the top on the next fresh load.
    private(set) var favoriteChannelIDs: Set<String> = []

    /// Timer-state overlay: programID -> (timerId, seriesTimerId). Seeded from fetched programs,
    /// updated optimistically so grid dot and reopened popover agree without refetching. nil member = no such timer.
    private(set) var timerState: [String: (timerId: String?, seriesTimerId: String?)] = [:]

    /// Sentinel for a create still in flight (server assigns the real id; reconcileTimers replaces).
    /// Toggles no-op on it so a double-tap can't DELETE /LiveTv/Timers/pending.
    private static let pendingTimerID = "pending"
    /// Bumped on every timerState change; the VC observes this (a dict of tuples isn't cheaply diffable).
    private(set) var timerStateVersion = 0
    /// Transient record-toggle error for the guide's alert.
    var recordingError: String?

    /// Guide axis start: floored to the previous half hour from now.
    let axisStart: Date
    let axisEnd: Date

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String
    private var nextChannelIndex = 0
    private var channelsExhausted = false
    /// Channel IDs whose programs have been requested already.
    private var requestedProgramChannelIDs: Set<String> = []

    init(service: JellyfinLiveTvServiceProtocol, userID: String, now: Date = Date()) {
        self.service = service
        self.userID = userID
        // Floor `now` to the previous :00 or :30 so cells align to the ruler.
        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)
        let flooredMinute = minute < 30 ? 0 : 30
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = flooredMinute
        let start = cal.date(from: comps) ?? now
        self.axisStart = start
        self.axisEnd = cal.date(byAdding: .hour, value: Self.windowHours, to: start)
            ?? start.addingTimeInterval(Double(Self.windowHours) * 3600)
    }

    /// X-offset in points for a given date on the guide axis.
    func xOffset(for date: Date) -> CGFloat {
        let minutes = date.timeIntervalSince(axisStart) / 60.0
        return CGFloat(minutes) * Self.pointsPerMinute
    }

    /// Width in points for a program spanning [start, end], clamped to the axis.
    func width(start: Date, end: Date) -> CGFloat {
        let clampedStart = max(start, axisStart)
        let clampedEnd = min(end, axisEnd)
        let minutes = max(0, clampedEnd.timeIntervalSince(clampedStart) / 60.0)
        return CGFloat(minutes) * Self.pointsPerMinute
    }

    /// Total width of the scrollable program area.
    var totalWidth: CGFloat {
        let minutes = axisEnd.timeIntervalSince(axisStart) / 60.0
        return CGFloat(minutes) * Self.pointsPerMinute
    }

    /// Half-hour tick marks for the time header.
    var timeTicks: [Date] {
        var ticks: [Date] = []
        var t = axisStart
        let cal = Calendar.current
        while t < axisEnd {
            ticks.append(t)
            t = cal.date(byAdding: .minute, value: 30, to: t) ?? axisEnd
        }
        return ticks
    }

    func loadInitialChannels() async {
        guard channels.isEmpty, !isLoadingChannels else { return }
        await loadMoreChannels()
    }

    func loadMoreChannels() async {
        guard !channelsExhausted, !isLoadingChannels else { return }
        isLoadingChannels = true
        defer { isLoadingChannels = false }
        do {
            let pageSize = 50
            let response = try await service.getChannels(
                userID: userID, startIndex: nextChannelIndex, limit: pageSize)
            channels.append(contentsOf: response.items)
            for ch in response.items where ch.isFavorite { favoriteChannelIDs.insert(ch.id) }
            nextChannelIndex += response.items.count
            if response.items.count < pageSize { channelsExhausted = true }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Whether a channel is currently favorited (UI source of truth).
    func isFavorite(_ channelID: String) -> Bool {
        favoriteChannelIDs.contains(channelID)
    }

    // MARK: - Timer state accessors

    func hasTimer(programID: String) -> Bool {
        let state = timerState[programID]
        return state?.timerId != nil || state?.seriesTimerId != nil
    }

    /// Effective timer state: the overlay entry (authoritative, reflects local toggles) when one
    /// exists, else the program's server snapshot. After a cancel the overlay holds (nil, ...) and
    /// must shadow the stale snapshot so the dead timer id is not resurrected.
    func effectiveTimerState(for program: JellyfinProgram) -> (timerId: String?, seriesTimerId: String?) {
        timerState[program.id] ?? (program.timerId, program.seriesTimerId)
    }

    /// Optimistically flip the local favorite set, persist, roll back on failure. Re-sorting
    /// (favorites first) happens on the next fresh load via EnableFavoriteSorting, not live, so the
    /// current scroll / focus position is preserved.
    func toggleFavorite(channelID: String) {
        let wasFavorite = favoriteChannelIDs.contains(channelID)
        if wasFavorite { favoriteChannelIDs.remove(channelID) }
        else { favoriteChannelIDs.insert(channelID) }
        let target = !wasFavorite
        Task {
            do {
                try await service.setFavorite(
                    userID: userID, channelID: channelID, isFavorite: target)
            } catch {
                if target { favoriteChannelIDs.remove(channelID) }
                else { favoriteChannelIDs.insert(channelID) }
            }
        }
    }

    /// Lazily fetch programs for not-yet-requested channels, as their rows become visible.
    func ensurePrograms(for channelIDs: [String]) async {
        let missing = channelIDs.filter { !requestedProgramChannelIDs.contains($0) }
        guard !missing.isEmpty else { return }
        missing.forEach { requestedProgramChannelIDs.insert($0) }
        do {
            let programs = try await service.getPrograms(
                channelIDs: missing, userID: userID, start: axisStart, end: axisEnd)
            var grouped = programsByChannel
            for program in programs {
                guard let cid = program.channelId else { continue }
                // MinEndDate overlap query is inclusive; a program ending exactly at axisStart has
                // zero span and renders as a 1pt sliver. Skip anything not reaching into the window.
                if let end = program.endDate, end <= axisStart { continue }
                grouped[cid, default: []].append(program)
                if program.timerId != nil || program.seriesTimerId != nil {
                    timerState[program.id] = (program.timerId, program.seriesTimerId)
                }
            }
            // Only newly fetched channels need sorting; the requestedProgramChannelIDs guard makes
            // each fetch a one-shot, so already-loaded channels stay sorted from their first fetch.
            for cid in missing {
                grouped[cid]?.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            }
            programsByChannel = grouped
            timerStateVersion += 1
        } catch {
            // Leave these program-less (grid shows placeholders); clear from requested set to allow retry.
            missing.forEach { requestedProgramChannelIDs.remove($0) }
        }
    }

    // MARK: - Record toggles

    /// Schedule or cancel a single-program recording, optimistically.
    func toggleRecord(program: JellyfinProgram) {
        let old = timerState[program.id]
        let effective = effectiveTimerState(for: program)
        if let timerID = effective.timerId {
            if timerID == Self.pendingTimerID { return }
            // Preserve the EFFECTIVE series id, not the overlay's: a series-spawned timer with no
            // overlay entry has old=nil, so (nil, old?.seriesTimerId) would erase the still-live
            // series rule and let the popover offer "Record Series" again, creating a server duplicate.
            timerState[program.id] = (nil, effective.seriesTimerId)
            timerStateVersion += 1
            Task {
                do { try await self.service.cancelTimer(timerID: timerID) }
                catch { self.rollbackTimerState(programID: program.id, to: old, error: error) }
            }
        } else {
            // Server assigns the real id; mark sentinel and reconcile from /LiveTv/Timers right
            // after. Same effective-id preservation as the cancel branch.
            timerState[program.id] = (Self.pendingTimerID, effective.seriesTimerId)
            timerStateVersion += 1
            Task {
                do {
                    try await self.service.createTimer(programID: program.id)
                    await self.reconcileTimers()
                } catch { self.rollbackTimerState(programID: program.id, to: old, error: error) }
            }
        }
    }

    /// Schedule or cancel a series recording rule, optimistically.
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
                    // Server cancels the rule's spawned episode timers too; clear every overlay entry
                    // tied to this series so dead dots/buttons vanish (mirrors RecordingsViewModel.cancelSeriesTimer).
                    self.clearSeriesOverlay(seriesTimerID: seriesID)
                }
                catch { self.rollbackTimerState(programID: program.id, to: old, error: error) }
            }
        } else {
            timerState[program.id] = (effective.timerId, Self.pendingTimerID)
            timerStateVersion += 1
            Task {
                do {
                    try await self.service.createSeriesTimer(programID: program.id)
                    await self.reconcileTimers()
                } catch { self.rollbackTimerState(programID: program.id, to: old, error: error) }
            }
        }
    }

    private func clearSeriesOverlay(seriesTimerID: String) {
        for (programID, state) in timerState where state.seriesTimerId == seriesTimerID {
            timerState[programID] = (nil, nil)
        }
        timerStateVersion += 1
    }

    private func rollbackTimerState(
        programID: String,
        to old: (timerId: String?, seriesTimerId: String?)?,
        error: Error
    ) {
        timerState[programID] = old
        timerStateVersion += 1
        recordingError = error.localizedDescription
    }

    /// After a create, replace sentinel ids with the server's real ones (and pick up series-spawned timers).
    private func reconcileTimers() async {
        guard let timers = try? await service.getTimers() else { return }
        for timer in timers {
            guard timer.status != "Cancelled" else { continue }
            guard let programID = timer.programId else { continue }
            timerState[programID] = (timer.id, timer.seriesTimerId ?? timerState[programID]?.seriesTimerId)
        }
        // A create the server didn't report back (e.g. a series rule that spawned no timer for this
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

    /// Full overlay sync against the server's timer lists, on return from the Recordings segment
    /// (where timers/rules can be cancelled outside this overlay); else the guide keeps stale dots
    /// and offers "Cancel Recording" for timers that 404.
    func syncTimersWithServer() async {
        async let timersTask = try? service.getTimers()
        async let seriesTask = try? service.getSeriesTimers()
        guard let timers = await timersTask else { return }
        let seriesTimers = await seriesTask

        let live = timers.filter { $0.status != "Cancelled" }
        let liveTimerIDs = Set(live.map(\.id))
        // Series-rule drops need the dedicated list: ids on live timers aren't a substitute (a rule
        // between airings has no live timer, would be wrongly dropped). On fetch failure, keep series state untouched.
        let seriesListAuthoritative = seriesTimers != nil
        let liveSeriesIDs = seriesTimers.map { Set($0.map(\.id)) } ?? []

        // Adopt server state for programs with live timers.
        for timer in live {
            guard let programID = timer.programId else { continue }
            timerState[programID] = (timer.id, timer.seriesTimerId ?? timerState[programID]?.seriesTimerId)
        }
        // Drop overlay ids the server no longer knows.
        for (programID, state) in timerState {
            var timerID = state.timerId
            var seriesID = state.seriesTimerId
            if let t = timerID, t != Self.pendingTimerID, !liveTimerIDs.contains(t) { timerID = nil }
            if seriesListAuthoritative,
               let s = seriesID, s != Self.pendingTimerID, !liveSeriesIDs.contains(s) { seriesID = nil }
            if timerID != state.timerId || seriesID != state.seriesTimerId {
                timerState[programID] = (timerID, seriesID)
            }
        }
        // Programs with ids only in the immutable snapshot (no overlay yet): a cancelled timer there
        // needs an explicit overriding overlay entry to shadow the stale snapshot in effectiveTimerState.
        for programs in programsByChannel.values {
            for program in programs where timerState[program.id] == nil {
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
        }
        timerStateVersion += 1
    }
}
