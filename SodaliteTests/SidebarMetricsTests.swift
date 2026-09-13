import Testing
import CoreGraphics
@testable import Sodalite

/// Sodalite#140. The 76pt pitch is measured off the system sidebar, so it is the fixed point:
/// everything else is derived from it and a retune of the icon or the padding must not move it.
struct SidebarMetricsTests {

    @Test("the spacing is derived so the measured pitch survives a retune")
    func pitchIsTheFixedPoint() {
        #expect(SidebarMetrics.rowPitch == 76)
        #expect(SidebarMetrics.itemHeight + SidebarMetrics.itemSpacing == SidebarMetrics.rowPitch)
        #expect(SidebarMetrics.itemSpacing > 0, "a bigger icon than the pitch allows would collapse the gap")
    }

    @Test("the collapsed rail is wide enough for the icon column it has to centre")
    func collapsedFitsTheIcon() {
        #expect(SidebarMetrics.collapsedWidth >= SidebarMetrics.iconColumn + SidebarMetrics.horizontalPadding * 2)
    }

    @Test("expanding is the only thing that changes the width")
    func widthFollowsExpansion() {
        #expect(SidebarMetrics.width(isExpanded: false) == SidebarMetrics.collapsedWidth)
        #expect(SidebarMetrics.width(isExpanded: true) == SidebarMetrics.expandedWidth)
    }

    @Test("the whole block fits the tvOS title-safe band, profile header included")
    func blockFitsTheBand() {
        // 1080 minus the 60pt safe inset top and bottom.
        let band: CGFloat = 960
        // Today's worst case: every optional tab present, so all six, plus the divider.
        #expect(SidebarMetrics.blockHeight(itemCount: 6, hasProfileHeader: true) <= band)
        // Headroom for the eleven rows the proposal imagines, so the geometry does not have to be
        // rethought if that ever lands.
        #expect(SidebarMetrics.blockHeight(itemCount: 11, hasProfileHeader: true) <= band)
    }
}
