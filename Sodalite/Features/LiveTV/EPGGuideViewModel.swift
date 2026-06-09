import SwiftUI
import Observation

@Observable
@MainActor
final class EPGGuideViewModel {
    // Layout constants
    /// Horizontal scale: points per minute of program time.
    static let pointsPerMinute: CGFloat = 6
    /// Height of a single channel row.
    static let rowHeight: CGFloat = 110
    /// Width of the sticky channel column.
    static let channelColumnWidth: CGFloat = 360
    /// How far ahead of `now` the guide axis extends.
    static let windowHours: Int = 24

    private(set) var channels: [JellyfinChannel] = []
    /// channelID -> its programs, sorted by startDate.
    private(set) var programsByChannel: [String: [JellyfinProgram]] = [:]
    private(set) var isLoadingChannels = false
    private(set) var loadError: String?
    /// Channel IDs the user has favorited. Seeded from each loaded page's
    /// server-side IsFavorite, then updated optimistically on toggle. The
    /// server-side EnableFavoriteSorting floats these to the top on the next
    /// fresh load; the star marker tracks this set live.
    private(set) var favoriteChannelIDs: Set<String> = []

    /// Guide axis start: floored to the previous half hour from now.
    let axisStart: Date
    /// Guide axis end.
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

    /// Toggle a channel's favorite state: flip the local set immediately for
    /// snappy feedback, then persist to the server. Roll back on failure.
    /// Re-sorting (favorites first) happens on the next fresh guide load via
    /// the server's EnableFavoriteSorting, not live, so the current scroll /
    /// focus position is preserved.
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
                // Revert the optimistic change.
                if target { favoriteChannelIDs.remove(channelID) }
                else { favoriteChannelIDs.insert(channelID) }
            }
        }
    }

    /// Lazily fetch programs for a set of channels not yet requested.
    /// Called by the view as channel rows become visible.
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
                grouped[cid, default: []].append(program)
            }
            // Only the newly fetched channels need sorting; already-loaded
            // channels were sorted on their first fetch and never refetched
            // (the requestedProgramChannelIDs guard makes each a one-shot).
            for cid in missing {
                grouped[cid]?.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            }
            programsByChannel = grouped
        } catch {
            // Leave these channels program-less; the grid shows placeholders.
            // Allow a retry by clearing them from the requested set.
            missing.forEach { requestedProgramChannelIDs.remove($0) }
        }
    }
}
