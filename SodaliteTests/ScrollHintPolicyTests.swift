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
        #expect(ScrollHintPolicy.primaryBottomInset(reservesHint: true) == 64)
        #expect(ScrollHintPolicy.primaryBottomInset(reservesHint: false) == 24)
    }
}
