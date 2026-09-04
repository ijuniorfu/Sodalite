import Testing
@testable import Sodalite

@Suite("Transport auto-hide and paused visibility (Sodalite#93, #110)")
struct TransportAutoHideTests {
    @Test("A fired auto-hide keeps a paused transport on screen")
    func pausedTransportSurvivesTheTimer() {
        #expect(TransportAutoHide.hides(isPlaying: false) == false)
        #expect(TransportAutoHide.hides(isPlaying: true) == true)
    }

    @Test("An ordinary pause raises the transport")
    func ordinaryPauseRaisesTransport() {
        #expect(TransportAutoHide.raisesTransport(errorVisible: false, inputLocked: false))
    }

    @Test("An error screen keeps the transport down so Menu still dismisses the player")
    func errorScreenKeepsTransportDown() {
        #expect(!TransportAutoHide.raisesTransport(errorVisible: true, inputLocked: false))
    }

    // MARK: - Music Now Playing chrome auto-hide (Sodalite#110)

    @Test("Paused music keeps its chrome on screen")
    func pausedChromeSurvivesTheTimer() {
        #expect(TransportAutoHide.hidesMusicChrome(isPlaying: false, queueHasFocus: false) == false)
        #expect(TransportAutoHide.hidesMusicChrome(isPlaying: true, queueHasFocus: false) == true)
    }

    @Test("A queue holding focus is never hidden out from under the user")
    func focusedQueueSurvivesTheTimer() {
        #expect(!TransportAutoHide.hidesMusicChrome(isPlaying: true, queueHasFocus: true))
        #expect(!TransportAutoHide.hidesMusicChrome(isPlaying: false, queueHasFocus: true))
    }

    @Test("The chrome rule is the transport rule plus the focus clause, nothing else")
    func chromeRuleExtendsTheTransportRule() {
        for playing in [true, false] {
            for focused in [true, false] {
                let expected = TransportAutoHide.hides(isPlaying: playing) && !focused
                #expect(TransportAutoHide.hidesMusicChrome(isPlaying: playing,
                                                           queueHasFocus: focused) == expected)
            }
        }
    }

    @Test("A single-track album fades its controls too, the queue count is the view's business")
    func singleTrackAlbumStillHidesItsControls() {
        // No queue rows means no queue focus, and that is the only extra clause the rule carries.
        #expect(TransportAutoHide.hidesMusicChrome(isPlaying: true, queueHasFocus: false))
    }

    @Test("Both auto-hides count down on the same delay")
    func sharedIdleDelay() {
        #expect(TransportAutoHide.idleDelay == .seconds(5))
    }

    @Test("The child lock keeps the transport down")
    func childLockKeepsTransportDown() {
        #expect(!TransportAutoHide.raisesTransport(errorVisible: false, inputLocked: true))
        #expect(!TransportAutoHide.raisesTransport(errorVisible: true, inputLocked: true))
    }
}
