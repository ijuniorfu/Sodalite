import Testing
@testable import Sodalite

/// Resume fraction for a Top Shelf cell. Jellyfin gives us a percentage on resume items and
/// raw ticks everywhere else; nil means "draw no bar", which is not the same as 0.
@MainActor
struct TopShelfProgressTests {

    @Test("percentage wins when both inputs are present")
    func percentagePreferred() {
        #expect(TopShelfProgress.fraction(playedPercentage: 25,
                                          positionTicks: 9_000_000_000,
                                          runTimeTicks: 10_000_000_000) == 0.25)
    }

    @Test("ticks are used when no percentage came back")
    func ticksFallback() {
        #expect(TopShelfProgress.fraction(playedPercentage: nil,
                                          positionTicks: 5_000_000_000,
                                          runTimeTicks: 10_000_000_000) == 0.5)
    }

    @Test("an unwatched item draws no bar")
    func zeroIsNil() {
        #expect(TopShelfProgress.fraction(playedPercentage: 0,
                                          positionTicks: 0,
                                          runTimeTicks: 10_000_000_000) == nil)
    }

    @Test("missing inputs draw no bar")
    func missingIsNil() {
        #expect(TopShelfProgress.fraction(playedPercentage: nil,
                                          positionTicks: nil,
                                          runTimeTicks: 10_000_000_000) == nil)
        #expect(TopShelfProgress.fraction(playedPercentage: nil,
                                          positionTicks: 5_000_000_000,
                                          runTimeTicks: nil) == nil)
    }

    @Test("a zero runtime cannot divide")
    func zeroRuntimeIsNil() {
        #expect(TopShelfProgress.fraction(playedPercentage: nil,
                                          positionTicks: 5_000_000_000,
                                          runTimeTicks: 0) == nil)
    }

    @Test("out of range values clamp to a full bar")
    func clampsAboveOne() {
        #expect(TopShelfProgress.fraction(playedPercentage: 140,
                                          positionTicks: nil,
                                          runTimeTicks: nil) == 1)
    }

    @Test("a negative position draws no bar")
    func negativeIsNil() {
        #expect(TopShelfProgress.fraction(playedPercentage: -5,
                                          positionTicks: nil,
                                          runTimeTicks: nil) == nil)
    }
}
