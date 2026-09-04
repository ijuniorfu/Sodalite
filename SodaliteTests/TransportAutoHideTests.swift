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

    // MARK: - Music queue auto-hide (Sodalite#110)

    @Test("A paused music queue stays on screen")
    func pausedQueueSurvivesTheTimer() {
        #expect(TransportAutoHide.hidesQueue(isPlaying: false, queueCount: 12, queueHasFocus: false) == false)
        #expect(TransportAutoHide.hidesQueue(isPlaying: true, queueCount: 12, queueHasFocus: false) == true)
    }

    @Test("A queue holding focus is never hidden out from under the user")
    func focusedQueueSurvivesTheTimer() {
        #expect(!TransportAutoHide.hidesQueue(isPlaying: true, queueCount: 12, queueHasFocus: true))
    }

    @Test("A single-track queue has nothing to hide, it is already centered")
    func singleTrackQueueNeverHides() {
        #expect(!TransportAutoHide.hidesQueue(isPlaying: true, queueCount: 1, queueHasFocus: false))
        #expect(!TransportAutoHide.hidesQueue(isPlaying: true, queueCount: 0, queueHasFocus: false))
        #expect(TransportAutoHide.hidesQueue(isPlaying: true, queueCount: 2, queueHasFocus: false))
    }

    @Test("The queue rule is the transport rule plus its own two conditions")
    func queueRuleExtendsTheTransportRule() {
        for playing in [true, false] {
            for count in [0, 1, 2, 9] {
                for focused in [true, false] {
                    let expected = TransportAutoHide.hides(isPlaying: playing) && count > 1 && !focused
                    #expect(TransportAutoHide.hidesQueue(isPlaying: playing,
                                                         queueCount: count,
                                                         queueHasFocus: focused) == expected)
                }
            }
        }
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
