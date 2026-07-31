import Testing
@testable import Sodalite

struct NextEpisodePolicyTests {

    // MARK: - Trigger window

    @Test func noOutroMarkerOpensThirtySecondsFromTheEnd() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 100, remainingSeconds: 45) == false)
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 100, remainingSeconds: 25) == true)
    }

    @Test func noOutroMarkerWindowIsStrictlyUnderThirty() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 100, remainingSeconds: 30) == false)
    }

    @Test func outroMarkerOpensAtItsStart() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 1200, sourceTime: 1199, remainingSeconds: 200) == false)
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 1200, sourceTime: 1200, remainingSeconds: 200) == true)
    }

    /// With a marker present the 30s fallback must not fire: a short outro would otherwise open the
    /// overlay before the credits it was meant to sit on.
    @Test func outroMarkerSupersedesTheRemainingFallback() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 1200, sourceTime: 1100, remainingSeconds: 10) == false)
    }

    /// The cancel latch is scoped to one pass through the window: scrubbing back out of it clears the
    /// cancel, so playing forward again re-triggers overlay + auto-advance.
    @Test func scrubbingOutOfTheWindowLeavesTheCancelScope() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 600, remainingSeconds: 900) == false)
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 1200, sourceTime: 600, remainingSeconds: 900) == false)
    }

    // MARK: - End-of-playback routing

    private func outcome(
        hasStartedPlaying: Bool = true,
        pictureInPictureActive: Bool = false,
        pictureInPictureCanAdvance: Bool = true,
        hasNextEpisode: Bool = true,
        advanceCancelled: Bool = false,
        countdownRunning: Bool = false,
        overlayVisible: Bool = false
    ) -> NextEpisodePolicy.EndOfPlaybackOutcome {
        NextEpisodePolicy.endOfPlaybackOutcome(
            hasStartedPlaying: hasStartedPlaying,
            pictureInPictureActive: pictureInPictureActive,
            pictureInPictureCanAdvance: pictureInPictureCanAdvance,
            hasNextEpisode: hasNextEpisode,
            advanceCancelled: advanceCancelled,
            countdownRunning: countdownRunning,
            overlayVisible: overlayVisible
        )
    }

    @Test func endBeforeFirstFrameIsIgnored() {
        #expect(outcome(hasStartedPlaying: false) == .ignore)
    }

    @Test func movieEndDismissesThePlayer() {
        #expect(outcome(hasNextEpisode: false) == .dismissPlayer)
    }

    @Test func episodeEndStartsTheAdvance() {
        #expect(outcome() == .showOverlayAndAdvance)
    }

    @Test func runningCountdownOwnsTheAdvance() {
        #expect(outcome(countdownRunning: true) == .ignore)
    }

    /// Regression: a cancelled advance used to match no branch at all, leaving the player open on a
    /// terminal engine session (seek and play are no-ops in `.ended`), i.e. a dead screen. A rejected
    /// next episode means "no successor for this session", so it routes like a movie's end.
    @Test func cancelledAdvanceDismissesThePlayer() {
        #expect(outcome(advanceCancelled: true) == .dismissPlayer)
    }

    @Test func cancelledAdvanceDismissesEvenWithACountdownStillRegistered() {
        #expect(outcome(advanceCancelled: true, countdownRunning: true) == .dismissPlayer)
    }

    /// The queue-exhausted overlay is already on screen; end-of-media must not dismiss out from under it.
    @Test func visibleOverlayWithoutASuccessorHoldsThePlayer() {
        #expect(outcome(hasNextEpisode: false, overlayVisible: true) == .ignore)
    }

    @Test func pipAdvancesInPlaceWhenTheBackendCan() {
        #expect(outcome(pictureInPictureActive: true) == .showOverlayAndAdvance)
    }

    @Test func pipClosesWhenTheBackendCannotAdvance() {
        #expect(outcome(pictureInPictureActive: true, pictureInPictureCanAdvance: false)
                == .endPictureInPicture)
    }

    @Test func pipClosesOnACancelledAdvance() {
        #expect(outcome(pictureInPictureActive: true, advanceCancelled: true) == .endPictureInPicture)
    }

    @Test func pipClosesAtRealEndOfContent() {
        #expect(outcome(pictureInPictureActive: true, hasNextEpisode: false) == .endPictureInPicture)
    }
}
