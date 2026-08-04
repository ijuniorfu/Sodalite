import SwiftUI
import Observation

/// EPG grid geometry that scales by platform + size class. tvOS (10-foot) keeps the shipped
/// values; iPad regular gets a middle tier; iPhone compact shrinks the channel column, row height,
/// time-slot scale, and header so the timeline fits a phone instead of collapsing behind the column.
struct EPGMetrics: Equatable {
    /// Horizontal scale, points per minute. 8 puts ~3.25h on a tv; lower tiers trade context for fit.
    var pointsPerMinute: CGFloat
    var rowHeight: CGFloat
    var channelColumnWidth: CGFloat
    var headerHeight: CGFloat
    var channelLogoSize: CGFloat
    var channelInset: CGFloat
    var channelSpacing: CGFloat
    var favoriteIconSize: CGFloat

    /// tvOS 10-foot tier: the current shipped values (keeps tvOS byte-identical).
    static let tv = EPGMetrics(
        pointsPerMinute: 8, rowHeight: 110, channelColumnWidth: 360, headerHeight: 60,
        channelLogoSize: 56, channelInset: 16, channelSpacing: 12, favoriteIconSize: 28)
    /// iPad regular tier.
    static let regular = EPGMetrics(
        pointsPerMinute: 6, rowHeight: 84, channelColumnWidth: 220, headerHeight: 48,
        channelLogoSize: 44, channelInset: 14, channelSpacing: 10, favoriteIconSize: 24)
    /// iPhone compact tier.
    static let compact = EPGMetrics(
        pointsPerMinute: 5, rowHeight: 64, channelColumnWidth: 132, headerHeight: 40,
        channelLogoSize: 30, channelInset: 10, channelSpacing: 8, favoriteIconSize: 18)

    /// Resolves the tier for the current platform + size class.
    static func current(_ sizeClass: UserInterfaceSizeClass?) -> EPGMetrics {
        #if os(tvOS)
        return .tv
        #else
        return sizeClass == .compact ? .compact : .regular
        #endif
    }
}

@Observable
@MainActor
final class EPGGuideViewModel {
    /// How far ahead of `now` the guide axis extends.
    static let windowHours: Int = 24

    /// Grid geometry, resolved by platform + size class at construction time.
    let metrics: EPGMetrics

    private(set) var channels: [JellyfinChannel] = []
    /// channelID -> its programs, sorted by startDate.
    private(set) var programsByChannel: [String: [JellyfinProgram]] = [:]
    private(set) var isLoadingChannels = false
    private(set) var loadError: String?
    /// Record timers and favorites live in the shared store, not here: Übersicht and the channel
    /// list must show the same optimistic state.
    let timers: LiveTimerStore

    /// Guide axis start: floored to the previous half hour from now.
    let axisStart: Date
    let axisEnd: Date

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String
    private var nextChannelIndex = 0
    private var channelsExhausted = false
    /// Channel IDs whose programs have been requested already.
    private var requestedProgramChannelIDs: Set<String> = []

    init(service: JellyfinLiveTvServiceProtocol, userID: String, timers: LiveTimerStore,
         metrics: EPGMetrics = .tv, now: Date = Date()) {
        self.service = service
        self.userID = userID
        self.timers = timers
        self.metrics = metrics
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
        return CGFloat(minutes) * metrics.pointsPerMinute
    }

    /// Width in points for a program spanning [start, end], clamped to the axis.
    func width(start: Date, end: Date) -> CGFloat {
        let clampedStart = max(start, axisStart)
        let clampedEnd = min(end, axisEnd)
        let minutes = max(0, clampedEnd.timeIntervalSince(clampedStart) / 60.0)
        return CGFloat(minutes) * metrics.pointsPerMinute
    }

    /// Total width of the scrollable program area.
    var totalWidth: CGFloat {
        let minutes = axisEnd.timeIntervalSince(axisStart) / 60.0
        return CGFloat(minutes) * metrics.pointsPerMinute
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
                userID: userID, startIndex: nextChannelIndex, limit: pageSize, filter: .default)
            channels.append(contentsOf: response.items)
            timers.seedFavorites(from: response.items)
            nextChannelIndex += response.items.count
            if response.items.count < pageSize { channelsExhausted = true }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
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
            }
            // Only newly fetched channels need sorting; the requestedProgramChannelIDs guard makes
            // each fetch a one-shot, so already-loaded channels stay sorted from their first fetch.
            for cid in missing {
                grouped[cid]?.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            }
            programsByChannel = grouped
            timers.seedTimers(from: programs)
        } catch {
            // Leave these program-less (grid shows placeholders); clear from requested set to allow retry.
            missing.forEach { requestedProgramChannelIDs.remove($0) }
        }
    }

    /// Every program currently loaded, for `LiveTimerStore.syncWithServer(knownPrograms:)`.
    var allLoadedPrograms: [JellyfinProgram] { programsByChannel.values.flatMap { $0 } }
}
