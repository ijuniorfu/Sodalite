import Foundation
import Observation

/// The iPhone's Live TV state. A grid at phone scale is not usable, so compact gets a channel list
/// that leads with what is on now and what follows, and defers the full schedule to a sheet.
@Observable
@MainActor
final class ChannelListViewModel {

    private(set) var channels: [JellyfinChannel] = []
    private(set) var programsByChannel: [String: [JellyfinProgram]] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var hasRadioChannels = false
    private(set) var filter: GuideFilter = .default
    private(set) var searchText = ""

    let timers: LiveTimerStore

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String
    private var fetchedChannels: [JellyfinChannel] = []
    private var requestedProgramChannelIDs: Set<String> = []
    private var loadGeneration = 0
    private var didLoad = false
    /// The list's own window: two days, the same horizon the grid uses.
    private let windowStart = Date()
    private var windowEnd: Date { windowStart.addingTimeInterval(GuideAxis.defaultSpan) }

    init(service: JellyfinLiveTvServiceProtocol, userID: String, timers: LiveTimerStore) {
        self.service = service
        self.userID = userID
        self.timers = timers
    }

    /// The two days the schedule sheet offers, matching the grid's axis.
    var scheduleDays: [Date] {
        [windowStart, Calendar.current.date(byAdding: .day, value: 1, to: windowStart) ?? windowStart]
    }

    // MARK: - Loading

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        await probeRadio()
        await fetchChannels()
    }

    /// Pull to refresh. Only the channel list is re-asked: the schedule behind each row spans two
    /// days and does not go stale, what goes stale is the row's "now", and that follows the clock
    /// rather than a request. `channels` is left standing until the first page lands, so the list
    /// does not blink empty under the user's finger.
    func refresh() async {
        loadGeneration += 1
        fetchedChannels = []
        await fetchChannels()
    }

    private func probeRadio() async {
        var probe = GuideFilter.default
        probe.kind = .radio
        let response = try? await service.getChannels(
            userID: userID, startIndex: 0, limit: 1, filter: probe)
        hasRadioChannels = !(response?.items.isEmpty ?? true)
    }

    func apply(filter newFilter: GuideFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        loadGeneration += 1
        fetchedChannels = []
        channels = []
        programsByChannel = [:]
        requestedProgramChannelIDs = []
        await fetchChannels()
    }

    func apply(searchText newValue: String) {
        searchText = newValue
        recomputeVisibleChannels()
    }

    private func fetchChannels() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let generation = loadGeneration
        var startIndex = fetchedChannels.count
        var complete = false
        while !complete, startIndex < GuideViewModel.channelHardCap {
            do {
                let response = try await service.getChannels(
                    userID: userID, startIndex: startIndex,
                    limit: GuideViewModel.pageSize, filter: filter)
                guard generation == loadGeneration else { return }
                fetchedChannels.append(contentsOf: response.items)
                timers.seedFavorites(from: response.items)
                startIndex += response.items.count
                if response.items.count < GuideViewModel.pageSize { complete = true }
                loadError = nil
                recomputeVisibleChannels()
            } catch {
                guard generation == loadGeneration else { return }
                loadError = ErrorText.user(for: error)
                return
            }
        }
    }

    private func recomputeVisibleChannels() {
        channels = searchText.isEmpty
            ? fetchedChannels
            : fetchedChannels.filter { GuideViewModel.matches(channel: $0, query: searchText) }
    }

    // MARK: - Programs

    func ensurePrograms(for channelIDs: [String]) async {
        let missing = channelIDs.filter { !requestedProgramChannelIDs.contains($0) }
        guard !missing.isEmpty else { return }
        missing.forEach { requestedProgramChannelIDs.insert($0) }
        do {
            let programs = try await service.getPrograms(
                channelIDs: missing, userID: userID, start: windowStart, end: windowEnd)
            var grouped = programsByChannel
            for program in programs {
                guard let channelID = program.channelId else { continue }
                grouped[channelID, default: []].append(program)
            }
            for channelID in missing {
                grouped[channelID]?.sort {
                    ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast)
                }
            }
            programsByChannel = grouped
            timers.seedTimers(from: programs)
        } catch {
            missing.forEach { requestedProgramChannelIDs.remove($0) }
        }
    }

    func schedule(for channel: JellyfinChannel) -> [JellyfinProgram] {
        programsByChannel[channel.id] ?? []
    }

    /// `AddCurrentProgram=true` already delivers this with the channel list, so the row's first line
    /// needs no extra request; the fetched schedule only refines it once loaded.
    func currentProgram(for channel: JellyfinChannel) -> JellyfinProgram? {
        Self.currentProgram(at: Date(), in: schedule(for: channel), fallback: channel.currentProgram)
    }

    /// What is airing at `reference`. The fallback is the snapshot the channel list arrived with, so
    /// it only answers for a channel whose schedule has not loaded yet; once it has, the row follows
    /// the schedule and the clock rather than that one moment (#96).
    static func currentProgram(at reference: Date, in schedule: [JellyfinProgram],
                               fallback: JellyfinProgram?) -> JellyfinProgram? {
        if let fromSchedule = schedule.first(where: { $0.isAiring(at: reference) }) {
            return fromSchedule
        }
        guard let fallback else { return nil }
        // A schedule that is loaded and says nothing is airing has answered; the snapshot would only
        // repeat a program that ended.
        return schedule.isEmpty ? fallback : nil
    }

    func nextProgram(for channel: JellyfinChannel) -> JellyfinProgram? {
        Self.nextProgram(after: Date(), in: schedule(for: channel))
    }

    /// First program starting at or after `reference`. A gap in the schedule is not an end: the
    /// entry after the gap is still what comes next.
    static func nextProgram(after reference: Date, in schedule: [JellyfinProgram]) -> JellyfinProgram? {
        schedule.first { program in
            guard let start = program.startDate else { return false }
            return start >= reference
        }
    }

    /// The channel's programs on one calendar day, for the schedule sheet.
    func schedule(for channel: JellyfinChannel, on day: Date) -> [JellyfinProgram] {
        let calendar = Calendar.current
        return (programsByChannel[channel.id] ?? []).filter { program in
            guard let start = program.startDate else { return false }
            return calendar.isDate(start, inSameDayAs: day)
        }
    }
}
