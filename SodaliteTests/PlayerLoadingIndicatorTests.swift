import Testing
import AetherEngine
@testable import Sodalite

/// The single spinner rule that replaced the old `state`-only stitching (AetherEngine#85). The win is the
/// two cases the host never saw before: a mid-stream rebuffer and a source stall / reconnect now raise the
/// spinner instead of freezing on the last frame.
struct PlayerLoadingIndicatorTests {

    @Test func hostLoadAlwaysShowsSpinnerRegardlessOfPhase() {
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: true, phase: .playing))
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: true, phase: .idle))
    }

    @Test func startupLoadingShowsSpinner() {
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .loading))
    }

    @Test func midStreamRebufferShowsSpinner() {
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .rebuffering))
    }

    @Test func sourceStallShowsSpinner() {
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .stalled(reconnecting: true)))
    }

    @Test func playingHidesSpinner() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .playing))
    }

    @Test func pausedHidesSpinner() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .paused))
    }

    @Test func seekingIsOwnedByScrubUINotTheSpinner() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .seeking))
    }

    @Test func endedAndIdleAndErrorHideSpinner() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .ended))
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .idle))
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .error("x")))
    }
}
