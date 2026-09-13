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

    @Test("the collapsed rail costs exactly the icon plus its own padding, no leftover white space")
    func collapsedIsAsNarrowAsItsIcon() {
        let padding = SidebarMetrics.itemHorizontalPadding(isExpanded: false)
        #expect(SidebarMetrics.collapsedWidth == SidebarMetrics.iconColumn + padding * 2)
        // Square around the icon, so the focus pill is a tile rather than a stretched capsule.
        #expect(padding == SidebarMetrics.itemVerticalPadding)
    }

    /// The first attempt at this used .title3 and guessed its size. On tvOS 26 title3 is 48pt, not
    /// the ~29 a phone habit suggests, so "Einstellungen" was truncated on device. The row uses
    /// .headline (38pt) now, and the budget is checked against that measured number.
    @Test("the label budget fits the longest label at the size the row actually uses")
    func expandedFitsTheLongestLabel() {
        let headlinePointSize: CGFloat = 38
        // Mixed-case Latin averages about half the point size per character; "Einstellungen" is 13.
        let longestLabelWidth = 13 * headlinePointSize * 0.5
        #expect(SidebarMetrics.labelWidthBudget >= longestLabelWidth)
        // And the size it replaced would NOT have fitted, which is why this test exists.
        #expect(SidebarMetrics.labelWidthBudget < 13 * 48 * 0.5)
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
