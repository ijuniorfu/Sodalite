import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Sodalite#104: turning the television off and on left the channel behind live, with no way back to
/// it. A suspended app reads nothing, so a live session that was playing when it went away returns
/// behind reality by the whole suspension, and the DVR window cannot close that gap: the window holds
/// what was READ, and the reading stopped where the suspension began. The badge can even read LIVE,
/// because the playhead really is next to a frontier that stopped moving.
///
/// The old gate asked only whether the pipeline had been torn down, which is a question about the
/// engine's bookkeeping and not about the broadcast. What separates the two cases is whether the
/// playhead MOVED while the app was away.
@Suite("A live session coming back from the background (Sodalite#104)")
struct LiveForegroundReturnTests {

    private typealias Return = PlayerHostController.LiveForegroundReturn

    private func decide(
        needsReload: Bool = false,
        tunerReleased: Bool = false,
        wasPlaying: Bool = true,
        away: TimeInterval,
        advance: TimeInterval
    ) -> Return {
        PlayerHostController.liveForegroundReturn(
            needsReload: needsReload, tunerReleased: tunerReleased, wasPlaying: wasPlaying,
            backgroundSeconds: away, playheadAdvance: advance)
    }

    /// Round 4: the retune took the VOD return's hold-paused rule, so a channel playing when the television
    /// went off came back paused, and on the software path black. It keeps the transport the viewer left.
    @Test func aRetuneKeepsTheTransportTheViewerLeft() {
        #expect(PlayerHostController.liveRetuneHoldsPaused(wasPlaying: true) == false)
        #expect(PlayerHostController.liveRetuneHoldsPaused(wasPlaying: false) == true)
    }

    /// The case the report describes: away for half a minute, the picture exactly where it was.
    @Test func aSuspendedSessionTunesAgain() {
        #expect(decide(away: 30, advance: 0) == .retune)
        #expect(decide(away: 600, advance: 0) == .retune)
    }

    /// Background audio and the tvOS PiP keepalive keep a session running, and one that played
    /// through is exactly as live as it was. Tuning it again would cost a rebuffer for nothing.
    @Test func aSessionThatPlayedThroughResumesInPlace() {
        #expect(decide(away: 30, advance: 29.4) == .resume)
        #expect(decide(away: 600, advance: 600) == .resume)
    }

    /// The pause is the viewer's own position, and the engine's resume clamp already says what the
    /// buffer could still hold. Tuning here would throw away a pause nobody asked to end.
    @Test func aPausedSessionKeepsItsPosition() {
        #expect(decide(wasPlaying: false, away: 30, advance: 0) == .resume)
        #expect(decide(wasPlaying: false, away: 600, advance: 0) == .resume)
    }

    /// An app switch of a few seconds leaves the session inside the edge tolerance, so the gap is not
    /// worth a tune.
    @Test func aShortGapIsNotWorthATune() {
        #expect(decide(away: 1, advance: 0) == .resume)
        #expect(decide(away: 4.9, advance: 0) == .resume)
        #expect(decide(away: 5.1, advance: 0) == .retune)
    }

    /// A torn-down pipeline tunes whatever the intent was: there is nothing left to resume, which is
    /// the behaviour this decision inherited and must keep.
    @Test func aTornDownPipelineAlwaysTunes() {
        #expect(decide(needsReload: true, wasPlaying: false, away: 1, advance: 0) == .retune)
        #expect(decide(needsReload: true, away: 1, advance: 1) == .retune)
    }

    /// Sodalite#147: the suspension closed the session server-side, so there is no stream left to
    /// resume onto. It outranks every other reading, the paused position included, because the pause
    /// is a position inside a buffer whose producer has been let go.
    @Test func aTunerReleasedOnTheWayOutAlwaysTunes() {
        #expect(decide(tunerReleased: true, wasPlaying: false, away: 1, advance: 0) == .retune)
        #expect(decide(tunerReleased: true, away: 30, advance: 30) == .retune)
    }

    /// The gate the live decision now sits in front of, unchanged: only a torn-down session pays the
    /// VOD reload, so a pipeline the engine's grace window kept alive is left alone.
    @Test func theTornDownGateStillReadsBookkeepingOnly() {
        #expect(PlayerHostController.foregroundReturnNeedsReload(state: .paused, backend: .none))
        #expect(!PlayerHostController.foregroundReturnNeedsReload(state: .playing, backend: .none))
        #expect(!PlayerHostController.foregroundReturnNeedsReload(state: .paused, backend: .software))
    }
}
