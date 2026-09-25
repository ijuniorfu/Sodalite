import Testing
import Foundation
@testable import Sodalite

/// The channel fetch loops of the guide grid and the iPhone channel list: what survives a filter switch
/// in the middle of paging.
@MainActor
struct LiveChannelLoadingTests {

    private var favorites: GuideFilter {
        var filter = GuideFilter.default
        filter.favoritesOnly = true
        return filter
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    // MARK: - Audit 2026-09-25 LTV-2

    /// The replacement fetch used to hit the `isLoading` re-entry guard and return, and the old loop then
    /// quit on its generation check: nobody fetched for the new filter and the grid sat on its spinner.
    @Test func aFilterSwitchMidPagingLoadsTheNewFilterInTheGuide() async {
        let service = ChannelStub(gateFirstDefaultPage: true)
        let model = GuideViewModel(service: service, userID: "u",
                                   timers: LiveTimerStore(service: service, userID: "u"), metrics: .tv)
        let first = Task { await model.load() }
        await settle { service.isHoldingDefaultPage }

        await model.apply(filter: favorites)
        service.releaseDefaultPage()
        await first.value

        #expect(model.channels.map(\.id) == ["f0", "f1"])
        #expect(model.channelsComplete)
        #expect(model.isLoadingChannels == false)
    }

    @Test func aFilterSwitchMidPagingLoadsTheNewFilterInTheChannelList() async {
        let service = ChannelStub(gateFirstDefaultPage: true)
        let model = ChannelListViewModel(service: service, userID: "u",
                                         timers: LiveTimerStore(service: service, userID: "u"))
        let first = Task { await model.load() }
        await settle { service.isHoldingDefaultPage }

        await model.apply(filter: favorites)
        service.releaseDefaultPage()
        await first.value

        #expect(model.channels.map(\.id) == ["f0", "f1"])
        #expect(model.isLoading == false)
    }
}

/// Default filter: one short page of three "d" channels, optionally held until released. Favorites: two
/// "f" channels. The one-item radio probe gets nothing.
private final class ChannelStub: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var gateArmed: Bool
    private var gate: CheckedContinuation<Void, Never>?
    /// Thrown by the next default-filter page request, then cleared.
    var nextDefaultPageError: Error?
    private(set) var defaultPageRequests = 0

    init(gateFirstDefaultPage: Bool = false) {
        self.gateArmed = gateFirstDefaultPage
    }

    var isHoldingDefaultPage: Bool { lock.withLock { gate != nil } }

    func releaseDefaultPage() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        held?.resume()
    }

    private func page(_ prefix: String, count: Int, from start: Int = 0) -> LiveTvChannelsResponse {
        LiveTvChannelsResponse(
            items: (start..<(start + count)).map {
                JellyfinChannel(id: "\(prefix)\($0)", name: "\(prefix)\($0)", channelNumber: nil,
                                imageTags: nil, currentProgram: nil, userData: nil)
            },
            totalRecordCount: nil)
    }

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        if limit == 1 { return LiveTvChannelsResponse(items: [], totalRecordCount: 0) }
        if filter.favoritesOnly { return page("f", count: 2) }
        defaultPageRequests += 1
        if let error = nextDefaultPageError {
            nextDefaultPageError = nil
            throw error
        }
        let hold = lock.withLock { () -> Bool in
            defer { gateArmed = false }
            return gateArmed
        }
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { gate = continuation }
            }
        }
        return page("d", count: 3, from: startIndex)
    }

    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] { [] }
    func getGuideInfo() async throws -> JellyfinGuideInfo { JellyfinGuideInfo(startDate: nil, endDate: nil) }
    func getRecommendedPrograms(userID: String, category: LiveProgramCategory, limit: Int) async throws -> [JellyfinProgram] { [] }
    func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws {}
    func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem] { [] }
    func getTimers() async throws -> [LiveTvTimer] { [] }
    func getSeriesTimers() async throws -> [LiveTvSeriesTimer] { [] }
    func createTimer(programID: String) async throws {}
    func cancelTimer(timerID: String) async throws {}
    func createSeriesTimer(programID: String) async throws {}
    func cancelSeriesTimer(timerID: String) async throws {}
}
