import Testing
@testable import Sodalite

/// #64: what picking an audio track does, which differs by session kind. The live answer is a
/// re-tune, because the engine refuses to re-point a forward-only live source in place, so the gate
/// has to be right in both directions: a needless re-tune costs the viewer seconds of black, and a
/// missing one leaves a picker that does nothing.
@Suite("Live audio switch")
struct LiveAudioSwitchTests {
    private func action(requested: Int, active: Int? = 1, isLive: Bool = true,
                        retuneInFlight: Bool = false) -> LiveAudioSwitch.Action {
        LiveAudioSwitch.action(requestedIndex: requested, activeIndex: active,
                               isLive: isLive, retuneInFlight: retuneInFlight)
    }

    @Test("VOD hands the pick to the engine, which re-points the running session")
    func vodSelectsInPlace() {
        #expect(action(requested: 2, isLive: false) == .selectInPlace(streamIndex: 2))
    }

    @Test("live re-tunes, since its source cannot be re-pointed")
    func liveRetunes() {
        #expect(action(requested: 2) == .retune(streamIndex: 2))
    }

    @Test("picking the track already playing costs nothing, on either kind")
    func sameTrackIsIgnored() {
        #expect(action(requested: 1, active: 1) == .ignore)
        #expect(action(requested: 1, active: 1, isLive: false) == .ignore)
    }

    @Test("with no active track settled yet, a pick still goes through")
    func noActiveTrackYet() {
        #expect(action(requested: 0, active: nil) == .retune(streamIndex: 0))
        #expect(action(requested: 0, active: nil, isLive: false) == .selectInPlace(streamIndex: 0))
    }

    @Test("a re-tune already in flight owns the session and is not interrupted")
    func inFlightRetuneWins() {
        #expect(action(requested: 2, retuneInFlight: true) == .ignore)
    }

    @Test("the in-flight guard is a live concern only; VOD has no re-tune to collide with")
    func inFlightDoesNotBlockVOD() {
        #expect(action(requested: 2, isLive: false, retuneInFlight: true) == .selectInPlace(streamIndex: 2))
    }
}
