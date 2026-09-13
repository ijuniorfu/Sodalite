#if os(iOS)
import Testing
import CoreGraphics
@testable import Sodalite

struct PlayerTouchInputTests {
    @Test func leftThirdSkipsBackward() {
        #expect(PlayerTouchInput.skipDirection(forTapX: 50, width: 900) == -1)
    }

    @Test func rightThirdSkipsForward() {
        #expect(PlayerTouchInput.skipDirection(forTapX: 850, width: 900) == 1)
    }

    @Test func middleDoesNotSkip() {
        #expect(PlayerTouchInput.skipDirection(forTapX: 450, width: 900) == nil)
    }

    @Test func zeroWidthDoesNotSkip() {
        #expect(PlayerTouchInput.skipDirection(forTapX: 0, width: 0) == nil)
    }

    @Test func upwardDragRaisesLevel() {
        #expect(PlayerTouchInput.levelDelta(translationY: -100, height: 400) > 0)
    }

    @Test func downwardDragLowersLevel() {
        #expect(PlayerTouchInput.levelDelta(translationY: 100, height: 400) < 0)
    }
}
#endif
