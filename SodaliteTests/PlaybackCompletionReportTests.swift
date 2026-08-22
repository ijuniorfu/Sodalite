import Testing
import Foundation
@testable import Sodalite

/// An episode watched to the end has to be REPORTED as watched to the end, because Jellyfin decides
/// "played" from the reported position and nothing else.
///
/// The threshold is measured, not assumed (live server, 2026-08-22): a stop reported at 91% of runtime
/// sets Played and clears the resume point, one at 90% stores the position and the item stays in
/// Continue Watching. The percentages below are chosen around that line.
struct PlaybackCompletionReportTests {

    /// A 50 minute episode with four minutes of credits: the outro marker sits at 92%, and the ten
    /// second countdown moves the switch barely past it. Six minutes of credits and it lands under the
    /// line, which is the reported case: a nearly full bar that never becomes a checkmark.
    private let runtime = Int64(50 * 60) * 10_000_000

    private func pct(_ value: Int64) -> Double {
        Double(value) / Double(runtime) * 100
    }

    @Test func advancingAtTheOutroMarkerReportsTheEpisodeAsFinished() {
        let atOutro = Int64(44 * 60) * 10_000_000   // 88%, below Jellyfin's line
        let reported = PlaybackCompletionReport.positionTicks(
            playhead: atOutro, runtimeTicks: runtime, reachedEndOfContent: true)
        #expect(reported == runtime)
        #expect(pct(reported) > 90)
    }

    /// Without this the same playhead reports 88%, which is exactly what left the episode on the shelf.
    @Test func theSamePlayheadOutsideTheEndWindowIsReportedAsItIs() {
        let midEpisode = Int64(44 * 60) * 10_000_000
        let reported = PlaybackCompletionReport.positionTicks(
            playhead: midEpisode, runtimeTicks: runtime, reachedEndOfContent: false)
        #expect(reported == midEpisode)
        #expect(pct(reported) < 90)
    }

    /// Leaving mid-episode must keep its resume point exactly; rounding up there would lose the place
    /// the viewer wanted back.
    @Test func leavingEarlyKeepsItsResumePoint() {
        let quarterIn = runtime / 4
        #expect(PlaybackCompletionReport.positionTicks(
            playhead: quarterIn, runtimeTicks: runtime, reachedEndOfContent: false) == quarterIn)
    }

    /// No runtime means nothing to round up to, and nothing for the server to compare against either.
    @Test func noRuntimeLeavesThePlayheadAlone() {
        let playhead = Int64(42 * 60) * 10_000_000
        #expect(PlaybackCompletionReport.positionTicks(
            playhead: playhead, runtimeTicks: nil, reachedEndOfContent: true) == playhead)
        #expect(PlaybackCompletionReport.positionTicks(
            playhead: playhead, runtimeTicks: 0, reachedEndOfContent: true) == playhead)
    }

    /// A container whose duration undershoots the playhead must not be rounded DOWN: that would move the
    /// report backwards, which is the one direction it may never go.
    @Test func aPlayheadPastTheRuntimeIsNeverPulledBack() {
        let past = runtime + 30 * 10_000_000
        #expect(PlaybackCompletionReport.positionTicks(
            playhead: past, runtimeTicks: runtime, reachedEndOfContent: true) == past)
    }

    /// The end window is the next-episode overlay's own, so the two cannot drift apart on what "over"
    /// means. With a marker the credits define it; without one, the last 30 seconds do.
    @Test func theEndWindowIsTheOneTheNextEpisodeCardOpensOn() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 2640, sourceTime: 2645, remainingSeconds: 360))
        #expect(!NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 2640, sourceTime: 2600, remainingSeconds: 400))
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 2990, remainingSeconds: 10))
    }
}
