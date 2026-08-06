import Testing
import Foundation
@testable import Sodalite

/// The phone row leads with "now" and "next". Both come out of one sorted schedule, and the edge
/// cases (a gap between programs, the last program of the window) are what make or break the row's
/// second line.
@MainActor
struct ChannelListRowTests {

    private func program(_ name: String, start: TimeInterval, end: TimeInterval) -> JellyfinProgram {
        JellyfinProgram(
            id: name, channelId: "c1", channelName: "Test", name: name, overview: nil,
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: end),
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }

    private var schedule: [JellyfinProgram] {
        [program("A", start: 0, end: 3600),
         program("B", start: 3600, end: 7200),
         program("C", start: 10_800, end: 14_400)]
    }

    @Test("next is the first program starting after the reference moment")
    func nextAfterAiring() {
        let now = Date(timeIntervalSince1970: 1800)
        #expect(ChannelListViewModel.nextProgram(after: now, in: schedule)?.name == "B")
    }

    @Test("a gap in the schedule still yields the following program, not nil")
    func nextAcrossGap() {
        // 7200 to 10800 has no program at all; the row must still name what comes next.
        let now = Date(timeIntervalSince1970: 8000)
        #expect(ChannelListViewModel.nextProgram(after: now, in: schedule)?.name == "C")
    }

    @Test("past the last program there is no next")
    func nextAtEndOfWindow() {
        let now = Date(timeIntervalSince1970: 20_000)
        #expect(ChannelListViewModel.nextProgram(after: now, in: schedule) == nil)
    }

    @Test("an empty schedule has no next")
    func nextWithoutSchedule() {
        #expect(ChannelListViewModel.nextProgram(after: Date(), in: []) == nil)
    }

    @Test("a program starting exactly now counts as next, not as already past")
    func nextAtExactBoundary() {
        let now = Date(timeIntervalSince1970: 3600)
        #expect(ChannelListViewModel.nextProgram(after: now, in: schedule)?.name == "B")
    }
}
