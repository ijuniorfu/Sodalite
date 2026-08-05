import Testing
import Foundation
import CoreGraphics
@testable import Sodalite

/// Overlapping EPG entries stacked two cells on the same pixels on a live IPTV server, and the one
/// behind kept taking focus while being invisible.
@Suite("Guide row overlap resolution")
struct GuideRowMathTests {

    /// A multiple of 1800 lands on :00 or :30 in every half-hour timezone, so the axis starts here
    /// without the floor moving it.
    private let base = Date(timeIntervalSince1970: 1_754_388_000)

    private func axis() -> GuideAxis {
        GuideAxis(now: base, pointsPerMinute: 8)
    }

    private func range(_ startMinutes: Double, _ endMinutes: Double) -> GuideTimeRange {
        GuideTimeRange(start: base.addingTimeInterval(startMinutes * 60),
                       end: base.addingTimeInterval(endMinutes * 60))
    }

    @Test("disjoint programs are all kept")
    func disjointKept() {
        let ranges: [GuideTimeRange?] = [range(0, 60), range(60, 90), range(90, 150)]
        #expect(GuideRowMath.keptIndices(ranges) == [0, 1, 2])
    }

    @Test("a program fully inside an earlier one is dropped")
    func coveredDropped() {
        let ranges: [GuideTimeRange?] = [range(0, 60), range(10, 30), range(60, 90)]
        #expect(GuideRowMath.keptIndices(ranges) == [0, 2])
    }

    @Test("an exact duplicate is dropped")
    func duplicateDropped() {
        let ranges: [GuideTimeRange?] = [range(0, 60), range(0, 60)]
        #expect(GuideRowMath.keptIndices(ranges) == [0])
    }

    @Test("a partial overlap is kept, it carries time the row does not show yet")
    func partialOverlapKept() {
        let ranges: [GuideTimeRange?] = [range(0, 60), range(50, 90)]
        #expect(GuideRowMath.keptIndices(ranges) == [0, 1])
    }

    @Test("a program without airtimes is kept, it is the row-wide fallback")
    func missingDatesKept() {
        let ranges: [GuideTimeRange?] = [nil]
        #expect(GuideRowMath.keptIndices(ranges) == [0])
    }

    @Test("disjoint programs span exactly their own time")
    func disjointSpans() {
        let spans = GuideRowMath.spans([range(0, 60), range(60, 90)], axis: axis())
        #expect(spans[0].x == 0)
        #expect(spans[0].width == CGFloat(60 * 8))
        #expect(spans[1].x == CGFloat(60 * 8))
        #expect(spans[1].width == CGFloat(30 * 8))
    }

    /// The point of the whole exercise: two cells must never sit on the same pixels.
    @Test("a partially overlapping program starts where the previous one ends")
    func partialOverlapTrimmed() {
        let spans = GuideRowMath.spans([range(0, 60), range(50, 90)], axis: axis())
        #expect(spans[0].x + spans[0].width == spans[1].x)
        #expect(spans[1].x == CGFloat(60 * 8))
        #expect(spans[1].width == CGFloat(30 * 8))
    }

    @Test("a program that began before the axis starts at the left edge")
    func clampedToAxisStart() {
        let spans = GuideRowMath.spans([range(-30, 30)], axis: axis())
        #expect(spans[0].x == 0)
        #expect(spans[0].width == CGFloat(30 * 8))
    }

    @Test("a program covered by its predecessor's span collapses instead of stacking")
    func coveredSpanCollapses() {
        // keptIndices removes these, but spans must not stack even if one slips through.
        let spans = GuideRowMath.spans([range(0, 60), range(10, 30)], axis: axis())
        #expect(spans[1].width == 0)
    }
}
