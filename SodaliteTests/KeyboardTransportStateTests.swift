import Testing
@testable import Sodalite

struct KeyboardTransportStateTests {

    // MARK: - Space

    @Test func spaceTogglesOnTheDownEdge() {
        var state = KeyboardTransportState()
        #expect(state.keyDown(.space) == .togglePlayPause)
    }

    /// The up edge must stay silent, or every press would toggle twice and land back where it started.
    @Test func spaceReleaseDoesNothing() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.space)
        #expect(state.keyUp(.space) == KeyboardTransportAction.none)
    }

    // MARK: - Arrow tap

    /// A tap is only known to be a tap once the key comes back up, so the down edge arms the hold
    /// timer and the jump happens on release.
    @Test func shortArrowPressJumpsOnRelease() {
        var state = KeyboardTransportState()
        #expect(state.keyDown(.rightArrow) == .armHold(direction: 1))
        #expect(state.keyUp(.rightArrow) == .jump(direction: 1))
    }

    @Test func leftArrowCarriesTheNegativeDirection() {
        var state = KeyboardTransportState()
        #expect(state.keyDown(.leftArrow) == .armHold(direction: -1))
        #expect(state.keyUp(.leftArrow) == .jump(direction: -1))
    }

    @Test func aSecondTapWorksAfterTheFirstCompleted() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.rightArrow)
        _ = state.keyUp(.rightArrow)
        #expect(state.keyDown(.rightArrow) == .armHold(direction: 1))
        #expect(state.keyUp(.rightArrow) == .jump(direction: 1))
    }

    // MARK: - Arrow hold

    @Test func heldArrowSpoolsWhenTheThresholdElapses() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.rightArrow)
        #expect(state.holdThresholdElapsed(for: .rightArrow) == .beginContinuousSeek(direction: 1))
    }

    /// Release after a spool commits the preview. It must NOT also jump, or the release would move
    /// the playhead a second time past where the spool left it.
    @Test func releaseAfterSpoolCommitsInsteadOfJumping() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.leftArrow)
        _ = state.holdThresholdElapsed(for: .leftArrow)
        #expect(state.keyUp(.leftArrow) == .endContinuousSeek)
    }

    /// The timer outlives the press it was armed for. Firing it after the key came up would start a
    /// spool nobody is holding, and nothing would ever end it.
    @Test func thresholdAfterReleaseIsIgnored() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.rightArrow)
        _ = state.keyUp(.rightArrow)
        #expect(state.holdThresholdElapsed(for: .rightArrow) == KeyboardTransportAction.none)
    }

    /// A stale timer from an earlier press must not spool the key that is held right now.
    @Test func thresholdForTheOtherArrowIsIgnored() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.rightArrow)
        #expect(state.holdThresholdElapsed(for: .leftArrow) == KeyboardTransportAction.none)
    }

    // MARK: - Repeat and overlap

    /// If the system ever delivers auto-repeat as fresh down edges, they must not re-arm the hold:
    /// the spool would restart from the current preview on every repeat.
    @Test func repeatedDownEdgesOfTheHeldKeyAreIgnored() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.rightArrow)
        #expect(state.keyDown(.rightArrow) == KeyboardTransportAction.none)
        _ = state.holdThresholdElapsed(for: .rightArrow)
        #expect(state.keyDown(.rightArrow) == KeyboardTransportAction.none)
    }

    /// A repeat burst must still end as one gesture: the release after it commits the spool once.
    @Test func repeatsDoNotChangeWhatTheReleaseMeans() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.rightArrow)
        _ = state.holdThresholdElapsed(for: .rightArrow)
        _ = state.keyDown(.rightArrow)
        #expect(state.keyUp(.rightArrow) == .endContinuousSeek)
    }

    @Test func theOppositeArrowIsIgnoredWhileOneIsHeld() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.rightArrow)
        #expect(state.keyDown(.leftArrow) == KeyboardTransportAction.none)
        #expect(state.keyUp(.leftArrow) == KeyboardTransportAction.none)
        #expect(state.keyUp(.rightArrow) == .jump(direction: 1))
    }

    /// Space stays live during a spool: it is a separate axis, and swallowing it would make the
    /// keyboard feel stuck while an arrow is down.
    @Test func spaceStillTogglesWhileAnArrowIsHeld() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.rightArrow)
        _ = state.holdThresholdElapsed(for: .rightArrow)
        #expect(state.keyDown(.space) == .togglePlayPause)
        #expect(state.keyUp(.rightArrow) == .endContinuousSeek)
    }

    // MARK: - Cancellation

    /// Losing the press (app backgrounded, player dismissed) has to close an engaged spool, or the
    /// preview stays up with no key to release it.
    @Test func cancelEndsAnEngagedSpool() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.leftArrow)
        _ = state.holdThresholdElapsed(for: .leftArrow)
        #expect(state.cancel() == .endContinuousSeek)
    }

    /// Cancelling a press that never reached the threshold must not jump: an interrupted press is
    /// not a tap.
    @Test func cancelBeforeTheThresholdDoesNotJump() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.leftArrow)
        #expect(state.cancel() == KeyboardTransportAction.none)
    }

    @Test func cancelClearsTheHeldKey() {
        var state = KeyboardTransportState()
        _ = state.keyDown(.leftArrow)
        _ = state.holdThresholdElapsed(for: .leftArrow)
        _ = state.cancel()
        #expect(state.keyUp(.leftArrow) == KeyboardTransportAction.none)
        #expect(state.keyDown(.rightArrow) == .armHold(direction: 1))
    }
}
