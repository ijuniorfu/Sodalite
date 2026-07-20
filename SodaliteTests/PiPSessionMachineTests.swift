import Testing
@testable import Sodalite

@Suite("PiP session machine")
struct PiPSessionMachineTests {
    typealias M = PiPSessionMachine

    @Test("begin activates an idle session")
    func beginActivates() {
        #expect(M.transition(.idle, .begin) == (.active, .none))
    }

    @Test("restore request re-presents and enters restoring")
    func restoreRepresents() {
        #expect(M.transition(.active, .restoreRequested) == (.restoring, .represent))
    }

    @Test("didStop after restore keeps playback, releases ownership")
    func didStopAfterRestore() {
        #expect(M.transition(.restoring, .didStop) == (.idle, .continueFullscreen))
    }

    @Test("didStop without restore closes the session")
    func didStopClosesSession() {
        #expect(M.transition(.active, .didStop) == (.idle, .closeSession))
    }

    @Test("preempt stops PiP and closes, from active and restoring")
    func preemptStopsAndCloses() {
        #expect(M.transition(.active, .preempt) == (.idle, .stopPiPAndClose))
        #expect(M.transition(.restoring, .preempt) == (.idle, .stopPiPAndClose))
    }

    @Test("preempt with no session is a no-op")
    func preemptIdleNoOp() {
        #expect(M.transition(.idle, .preempt) == (.idle, .none))
    }

    @Test("player dismissed after restore releases refs without stopping playback")
    func playerDismissedReleases() {
        #expect(M.transition(.idle, .playerDismissed) == (.idle, .releaseRefs))
        #expect(M.transition(.active, .playerDismissed) == (.idle, .releaseRefs))
    }

    @Test("stray events while idle are no-ops")
    func strayEventsIdle() {
        #expect(M.transition(.idle, .restoreRequested) == (.idle, .none))
        #expect(M.transition(.idle, .didStop) == (.idle, .none))
    }
}
