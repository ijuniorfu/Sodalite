#if os(iOS)
import Testing
import CoreGraphics
@testable import Sodalite

struct PlayerTouchInputTests {
    @Test func leftThirdSkipsBackward() {
        #expect(PlayerTouchInput.skipSeconds(forTapX: 50, width: 900, interval: 10) == -10)
    }

    @Test func rightThirdSkipsForward() {
        #expect(PlayerTouchInput.skipSeconds(forTapX: 850, width: 900, interval: 10) == 10)
    }

    @Test func middleDoesNotSkip() {
        #expect(PlayerTouchInput.skipSeconds(forTapX: 450, width: 900, interval: 10) == nil)
    }

    @Test func zeroWidthDoesNotSkip() {
        #expect(PlayerTouchInput.skipSeconds(forTapX: 0, width: 0, interval: 10) == nil)
    }

    @Test func upwardDragRaisesLevel() {
        #expect(PlayerTouchInput.levelDelta(translationY: -100, height: 400) > 0)
    }

    @Test func downwardDragLowersLevel() {
        #expect(PlayerTouchInput.levelDelta(translationY: 100, height: 400) < 0)
    }
}
#endif
