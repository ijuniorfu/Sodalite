import Foundation
import Testing
@testable import Sodalite

@Suite("Scroll hint policy")
struct ScrollHintPolicyTests {

    @Test("hidden until the present transition has settled")
    func requiresSettle() {
        #expect(ScrollHintPolicy.isVisible(
            scrollOffset: 0, belowFoldHeight: 900, hasSettled: false) == false)
        #expect(ScrollHintPolicy.isVisible(
            scrollOffset: 0, belowFoldHeight: 900, hasSettled: true) == true)
    }

    /// The overlay appends a 600pt trailing filler, so every detail page is technically
    /// scrollable. Without this gate a movie with no overview, cast, tech info or similar
    /// items would point at an empty black field.
    @Test("hidden when there is nothing below the fold")
    func requiresContent() {
        #expect(ScrollHintPolicy.isVisible(
            scrollOffset: 0, belowFoldHeight: 0, hasSettled: true) == false)
    }

    @Test("hides as soon as the page scrolls")
    func hidesOnScroll() {
        #expect(ScrollHintPolicy.isVisible(
            scrollOffset: 7, belowFoldHeight: 900, hasSettled: true) == true)
        #expect(ScrollHintPolicy.isVisible(
            scrollOffset: 8, belowFoldHeight: 900, hasSettled: true) == false)
        #expect(ScrollHintPolicy.isVisible(
            scrollOffset: 400, belowFoldHeight: 900, hasSettled: true) == false)
    }

    /// Rubber-band overscroll at the top reports a negative offset; that is still the top.
    @Test("negative overscroll still counts as the top")
    func negativeOffsetIsTop() {
        #expect(ScrollHintPolicy.isVisible(
            scrollOffset: -30, belowFoldHeight: 900, hasSettled: true) == true)
    }

    /// The band is reserved whether or not the chevron is currently drawn, otherwise the
    /// first page jumps when it fades out.
    @Test("reserved band is independent of visibility")
    func bandIsConstant() {
        #expect(ScrollHintPolicy.primaryBottomInset(reservesHint: true) == 180)
        #expect(ScrollHintPolicy.primaryBottomInset(reservesHint: false) == 24)
    }

    /// The band's value is the focus engine's parking distance, and that is not a coincidence to be
    /// tidied away: at anything less, tvOS scrolls the page down by the difference the moment it can,
    /// which is how the page ended up resting 116 pt off its own fold (Sodalite#146 round 2).
    @Test("the band is what the focus engine wants below the focused control")
    func bandMeetsTheParkingDistance() {
        #expect(ScrollHintPolicy.primaryBottomInset(reservesHint: true)
                == ScrollHintPolicy.focusParkingDistance)
    }

    /// The chevron belongs to the block above it, not to the screen edge.
    @Test("the chevron stays under the action row")
    func hintSitsUnderTheActions() {
        let gap = ScrollHintPolicy.primaryBottomInset(reservesHint: true)
            - ScrollHintPolicy.hintBottomInset(reservesHint: true)
        #expect(gap == 54)
    }
}
