import Testing
@testable import Sodalite

/// The state machine behind "the server is gone", i.e. the difference between a stall the engine will
/// still recover from and one that no amount of reconnecting can fix. The probing timer around it is a
/// thin shell (`SourceOutageWatchdog`); everything that decides anything lives here.
///
/// Probe results go through a local `let` before every `#expect`: the macro captures its argument
/// expression into a non-mutating closure, so calling a `mutating` member inside one does not compile.
struct SourceOutageTrackerTests {

    @Test func idleTrackerAsksForNoProbes() {
        let tracker = SourceOutageTracker()
        #expect(!tracker.wantsProbe)
    }

    @Test func stallArmsProbing() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        #expect(tracker.wantsProbe)
    }

    @Test func aServerThatAnswersClearsTheStreak() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        let first = tracker.recordProbe(succeeded: false)
        let second = tracker.recordProbe(succeeded: false)
        let third = tracker.recordProbe(succeeded: true)
        #expect(!first)
        #expect(!second)
        #expect(!third)
        #expect(tracker.failures == 0)
    }

    @Test func threeFailuresInARowCallTheOutage() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        let first = tracker.recordProbe(succeeded: false)
        let second = tracker.recordProbe(succeeded: false)
        let third = tracker.recordProbe(succeeded: false)
        #expect(!first)
        #expect(!second)
        #expect(third)
    }

    /// The verdict fires once per stall. Without the latch a watchdog whose owner ignores the first call
    /// would re-enter the error path on every following probe.
    @Test func verdictIsReportedOnce() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        for _ in 0..<(SourceOutageTracker.failuresBeforeVerdict - 1) {
            _ = tracker.recordProbe(succeeded: false)
        }
        let verdict = tracker.recordProbe(succeeded: false)
        let again = tracker.recordProbe(succeeded: false)
        #expect(verdict)
        #expect(!again)
        #expect(!tracker.wantsProbe, "a called outage stops the probing")
    }

    @Test func leavingTheStallAxisDisarmsAndClearsTheStreak() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        _ = tracker.recordProbe(succeeded: false)
        _ = tracker.recordProbe(succeeded: false)
        tracker.setStalled(false)
        #expect(!tracker.wantsProbe)
        #expect(tracker.failures == 0)
        tracker.setStalled(true)
        let afterRearm = tracker.recordProbe(succeeded: false)
        #expect(!afterRearm, "the streak restarts, it does not resume")
    }

    /// iOS keeps playing audio in the background on purpose (AetherEngine#127 grace). Throwing the user
    /// out of a backgrounded session because the probe could not run would be wrong, so an inactive app
    /// probes not at all.
    @Test func inactiveAppDoesNotProbe() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        tracker.setActive(false)
        #expect(!tracker.wantsProbe)
        tracker.setActive(true)
        #expect(tracker.wantsProbe)
    }

    /// Coming back to an app that was inactive mid-stall must not inherit a stale streak: the failures
    /// counted before the pause say nothing about the link now.
    @Test func returningToActiveRestartsTheStreak() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        _ = tracker.recordProbe(succeeded: false)
        _ = tracker.recordProbe(succeeded: false)
        tracker.setActive(false)
        tracker.setActive(true)
        let afterReturn = tracker.recordProbe(succeeded: false)
        #expect(tracker.failures == 1)
        #expect(!afterReturn)
    }

    /// After a retry the same tracker serves the new session, so the latch has to come off with it.
    @Test func resetClearsTheCalledVerdict() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        for _ in 0..<SourceOutageTracker.failuresBeforeVerdict {
            _ = tracker.recordProbe(succeeded: false)
        }
        tracker.reset()
        #expect(!tracker.wantsProbe)
        #expect(tracker.failures == 0)
        tracker.setStalled(true)
        #expect(tracker.wantsProbe)
    }

    /// A probe result that arrives after the stall ended (the request was already in flight) must not
    /// count: the axis it was asked about is gone.
    @Test func probeResultAfterDisarmIsIgnored() {
        var tracker = SourceOutageTracker()
        tracker.setStalled(true)
        _ = tracker.recordProbe(succeeded: false)
        _ = tracker.recordProbe(succeeded: false)
        tracker.setStalled(false)
        let late = tracker.recordProbe(succeeded: false)
        #expect(!late)
        #expect(tracker.failures == 0)
    }
}
