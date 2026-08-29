import Testing
@testable import Sodalite

@Suite("Transport auto-hide and paused visibility (Sodalite#93)")
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

    @Test("The child lock keeps the transport down")
    func childLockKeepsTransportDown() {
        #expect(!TransportAutoHide.raisesTransport(errorVisible: false, inputLocked: true))
        #expect(!TransportAutoHide.raisesTransport(errorVisible: true, inputLocked: true))
    }
}
