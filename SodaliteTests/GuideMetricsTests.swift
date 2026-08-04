import Testing
import Foundation
@testable import Sodalite

/// The ruler lays its chips out at `slotWidth` while the grid draws gridlines from
/// `GuideAxis.slots`, and the two scroll views copy offsets straight across. If the tier's scale
/// and the axis ever disagree, the ruler labels drift off the columns they name: invisible in code
/// review, obvious on screen.
struct GuideMetricsTests {

    @Test("slot width is the axis slot at the tier's scale")
    func slotWidthMatchesAxis() {
        let minutes = CGFloat(GuideAxis.slotMinutes)
        #expect(GuideMetrics.tv.slotWidth == minutes * GuideMetrics.tv.pointsPerMinute)
        #expect(GuideMetrics.regular.slotWidth == minutes * GuideMetrics.regular.pointsPerMinute)
        #expect(GuideMetrics.tv.slotWidth == 240)
        #expect(GuideMetrics.regular.slotWidth == 180)
    }

    @Test("a tier's scale and the axis agree on total width")
    func axisWidthMatchesTier() {
        for metrics in [GuideMetrics.tv, GuideMetrics.regular] {
            let axis = GuideAxis(now: Date(), pointsPerMinute: metrics.pointsPerMinute)
            #expect(axis.slotWidth == metrics.slotWidth)
            #expect(axis.totalWidth == CGFloat(axis.slots.count) * metrics.slotWidth)
        }
    }

    @Test("the tv tier leaves at least three hours of timeline on a 1920pt screen")
    func tvShowsThreeHours() {
        let timeline = 1920 - GuideMetrics.tv.channelColumnWidth
        #expect(timeline / GuideMetrics.tv.pointsPerMinute >= 180)
    }

    @Test("the tv tier leaves room for at least six channel rows")
    func tvFitsSixRows() {
        // What is left under the tvOS tab bar (~100pt of top safe area) and the segment picker
        // (20pt padding plus a ~70pt control) on a 1080pt screen.
        let available: CGFloat = 880
        let chrome = GuideMetrics.tv.heroHeight
            + GuideMetrics.tv.controlsHeight
            + GuideMetrics.tv.rulerHeight
        #expect((available - chrome) / GuideMetrics.tv.rowHeight >= 6)
    }

    @Test("the ipad tier stays narrower than the tv tier in every dimension it shares")
    func regularIsSmallerThanTV() {
        #expect(GuideMetrics.regular.heroHeight < GuideMetrics.tv.heroHeight)
        #expect(GuideMetrics.regular.rowHeight < GuideMetrics.tv.rowHeight)
        #expect(GuideMetrics.regular.channelColumnWidth < GuideMetrics.tv.channelColumnWidth)
        #expect(GuideMetrics.regular.pointsPerMinute < GuideMetrics.tv.pointsPerMinute)
    }
}
