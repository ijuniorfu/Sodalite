import Testing
@testable import Sodalite

// Not #if os(iOS): the SodaliteTests target builds for tvOS, so an iOS-guarded test never runs.
// PlayerLockProgress is a pure, cross-platform helper (Sodalite/Player/), so these tests run on tvOS.
struct PlayerLockProgressTests {
    @Test func startsAtZero() {
        #expect(PlayerLockProgress.fraction(elapsed: 0, duration: 2) == 0)
    }

    @Test func halfwayIsHalf() {
        #expect(PlayerLockProgress.fraction(elapsed: 1, duration: 2) == 0.5)
    }

    @Test func clampsAboveOne() {
        #expect(PlayerLockProgress.fraction(elapsed: 5, duration: 2) == 1)
    }

    @Test func negativeElapsedClampsToZero() {
        #expect(PlayerLockProgress.fraction(elapsed: -1, duration: 2) == 0)
    }

    @Test func zeroDurationIsZero() {
        #expect(PlayerLockProgress.fraction(elapsed: 1, duration: 0) == 0)
    }

    @Test func completeOnlyAtFullHold() {
        #expect(PlayerLockProgress.isComplete(0.99) == false)
        #expect(PlayerLockProgress.isComplete(1.0) == true)
    }

    @Test func defaultHoldDurationIsTwoSeconds() {
        #expect(PlayerLockProgress.holdDuration == 2.0)
    }
}
