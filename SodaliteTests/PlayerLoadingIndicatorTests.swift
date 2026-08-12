import Testing
import AetherEngine
@testable import Sodalite

/// The single spinner rule that replaced the old `state`-only stitching (AetherEngine#85). The win is the
/// two cases the host never saw before: a mid-stream rebuffer and a source stall / reconnect now raise the
/// spinner instead of freezing on the last frame.
struct PlayerLoadingIndicatorTests {

    @Test func hostLoadAlwaysShowsSpinnerRegardlessOfPhase() {
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: true, phase: .playing, isBuffering: false))
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: true, phase: .idle, isBuffering: false))
    }

    @Test func startupLoadingShowsSpinner() {
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .loading, isBuffering: false))
    }

    @Test func midStreamRebufferShowsSpinner() {
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .rebuffering, isBuffering: true))
    }

    /// The reported case: the origin died, the reader is reconnecting, but the local HLS server still
    /// feeds AVPlayer out of the segment cache. Blacking the screen out there hid a running picture and
    /// left the audio playing behind it.
    @Test func sourceStallWithPictureStillRunningKeepsTheSpinnerDown() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false,
                                                     phase: .stalled(reconnecting: true),
                                                     isBuffering: false))
    }

    @Test func sourceStallThatRanTheBufferDryShowsSpinner() {
        #expect(PlayerLoadingIndicator.showsSpinner(hostLoadActive: false,
                                                    phase: .stalled(reconnecting: true),
                                                    isBuffering: true))
    }

    @Test func playingHidesSpinner() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .playing, isBuffering: false))
    }

    @Test func pausedHidesSpinner() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .paused, isBuffering: false))
    }

    @Test func seekingIsOwnedByScrubUINotTheSpinner() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .seeking, isBuffering: true))
    }

    @Test func endedAndIdleAndErrorHideSpinner() {
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .ended, isBuffering: false))
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .idle, isBuffering: false))
        #expect(!PlayerLoadingIndicator.showsSpinner(hostLoadActive: false, phase: .error("x"), isBuffering: false))
    }
}
