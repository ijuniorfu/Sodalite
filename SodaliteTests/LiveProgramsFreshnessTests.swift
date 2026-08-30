import Testing
import Foundation
@testable import Sodalite

/// Sodalite#96: the Übersicht rows come from `/LiveTv/Programs/Recommended`, which answers a
/// question about the current moment. The guide survives the passing of time because its cells are
/// placed by absolute time; these rows are a snapshot, so they need an expiry and a refetch.
@MainActor
struct LiveProgramsFreshnessTests {

    private func program(_ name: String, start: Date, end: Date) -> JellyfinProgram {
        JellyfinProgram(
            id: name, channelId: "c1", channelName: "Test", name: name, overview: nil,
            startDate: start, endDate: end,
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    // MARK: - Expiry

    @Test("the first airing program to end sets the expiry")
    func expiryIsEarliestAiringEnd() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [LiveProgramCategory: [JellyfinProgram]] = [
            .airing: [program("long", start: now - 600, end: now + 3600),
                      program("short", start: now - 600, end: now + 900)],
            .movies: [program("movie", start: now - 60, end: now + 1800)],
        ]
        #expect(LiveProgramsViewModel.expiry(for: rows, loadedAt: now) == now + 900)
    }

    @Test("a program that is not airing yet does not set the expiry")
    func upcomingProgramsDoNotExpireTheSnapshot() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [LiveProgramCategory: [JellyfinProgram]] = [
            .airing: [program("airing", start: now - 60, end: now + 3600)],
            .movies: [program("tonight", start: now + 300, end: now + 600)],
        ]
        // now+600 is the earlier end date, but that program has not started, so nothing on screen
        // changes when it ends.
        #expect(LiveProgramsViewModel.expiry(for: rows, loadedAt: now) == now + 3600)
    }

    @Test("a program about to end still buys the snapshot its minimum lifetime")
    func expiryHasAFloor() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [LiveProgramCategory: [JellyfinProgram]] = [
            .airing: [program("ending", start: now - 3600, end: now + 10)],
        ]
        #expect(LiveProgramsViewModel.expiry(for: rows, loadedAt: now)
                == now + LiveProgramsViewModel.minimumLifetime)
    }

    @Test("nothing airing means nothing to expire on, so the snapshot gets the blind lifetime")
    func expiryWithoutAiringPrograms() {
        let now = Date(timeIntervalSince1970: 10_000)
        let rows: [LiveProgramCategory: [JellyfinProgram]] = [
            .movies: [program("tonight", start: now + 3600, end: now + 7200)],
        ]
        #expect(LiveProgramsViewModel.expiry(for: rows, loadedAt: now)
                == now + LiveProgramsViewModel.unknownScheduleLifetime)
    }

    @Test("an empty answer expires too, so an empty guide is retried rather than kept forever")
    func expiryWithoutRows() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(LiveProgramsViewModel.expiry(for: [:], loadedAt: now)
                == now + LiveProgramsViewModel.unknownScheduleLifetime)
    }

    // MARK: - Refetch policy

    @Test("a second load does not hit the server, and an unexpired refresh does not either")
    func freshSnapshotIsNotRefetched() async {
        let service = StubLiveTvService(airingFor: 1800)
        let model = LiveProgramsViewModel(service: service, userID: "u")

        await model.load()
        let afterFirst = service.requestCount
        #expect(afterFirst == LiveProgramCategory.allCases.count)

        await model.load()
        await model.refreshIfExpired(now: Date())
        #expect(service.requestCount == afterFirst)
    }

    @Test("past the expiry the rows are refetched")
    func expiredSnapshotIsRefetched() async {
        let service = StubLiveTvService(airingFor: 1800)
        let model = LiveProgramsViewModel(service: service, userID: "u")

        await model.load()
        let afterFirst = service.requestCount
        await model.refreshIfExpired(now: Date().addingTimeInterval(3600))
        #expect(service.requestCount == afterFirst * 2)
        #expect(model.rows[.airing]?.isEmpty == false)
    }

    @Test("a refresh that fails everywhere keeps the rows it already had, without an error page")
    func failedRefreshKeepsRows() async {
        let service = StubLiveTvService(airingFor: 1800)
        let model = LiveProgramsViewModel(service: service, userID: "u")
        await model.load()
        #expect(model.rows.isEmpty == false)

        service.failing = true
        await model.refresh()
        #expect(model.rows.isEmpty == false)
        #expect(model.loadError == nil)
    }

    @Test("a first load that fails everywhere reports it and stays retryable")
    func failedFirstLoadIsRetryable() async {
        let service = StubLiveTvService(airingFor: 1800)
        service.failing = true
        let model = LiveProgramsViewModel(service: service, userID: "u")

        await model.load()
        #expect(model.loadError != nil)
        #expect(model.validUntil == nil)

        service.failing = false
        await model.load()
        #expect(model.rows.isEmpty == false)
        #expect(model.loadError == nil)
    }
}

/// Counts recommended-programs calls and can be made to fail; every other endpoint is unused here.
private final class StubLiveTvService: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    /// Seconds the returned program still has to run, measured from the moment it is asked for.
    let airingFor: TimeInterval
    var failing = false

    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }

    init(airingFor: TimeInterval) { self.airingFor = airingFor }

    func getRecommendedPrograms(userID: String, category: LiveProgramCategory,
                                limit: Int) async throws -> [JellyfinProgram] {
        lock.withLock { count += 1 }
        if failing { throw URLError(.notConnectedToInternet) }
        let now = Date()
        return [JellyfinProgram(
            id: "\(category.rawValue)-1", channelId: "c1", channelName: "Test",
            name: category.rawValue, overview: nil,
            startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(airingFor),
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)]
    }

    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        LiveTvChannelsResponse(items: [], totalRecordCount: 0)
    }
    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] { [] }
    func getGuideInfo() async throws -> JellyfinGuideInfo { JellyfinGuideInfo(startDate: nil, endDate: nil) }
    func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws {}
    func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem] { [] }
    func getTimers() async throws -> [LiveTvTimer] { [] }
    func getSeriesTimers() async throws -> [LiveTvSeriesTimer] { [] }
    func createTimer(programID: String) async throws {}
    func cancelTimer(timerID: String) async throws {}
    func createSeriesTimer(programID: String) async throws {}
    func cancelSeriesTimer(timerID: String) async throws {}
}
