import AetherEngine

/// Single rule for the player's loading spinner (`PlayerViewModel.isLoading`).
///
/// The spinner shows while either the host is still bringing a session up (`hostLoadActive`: fetching
/// playback info, calling `player.load()`, or running a live retune) or the engine's `playbackPhase`
/// reports startup / mid-stream work. Adopting `playbackPhase` is what lets a mid-stream rebuffer or a
/// source stall / reconnect (429 / 503) raise the spinner instead of freezing on the last frame
/// (AetherEngine#85); the old code only watched `state` transitions and never saw `isBuffering`.
///
/// `.stalled` is the reader's NETWORK axis, not a statement about the picture: `PlaybackPhase.derive`
/// ranks it above `playing` while `state` stays `.playing`, and on the loopback path the local HLS server
/// keeps feeding AVPlayer from the segment cache after the origin dies. Raising the spinner there painted
/// an opaque black layer over a picture that was still running, with the audio audible behind it. So a
/// stall raises it only once `isBuffering` says AVPlayer has actually run dry; until then the viewer keeps
/// the picture and `PlayerOverlayView`'s connection chip explains what is going on.
///
/// `.seeking` is owned by the scrub UI, so it never raises the spinner here. The live cold-transcode
/// debounce (a premature first `.playing`) is a timing concern handled by `PlayerViewModel`, not this rule.
enum PlayerLoadingIndicator {
    static func showsSpinner(hostLoadActive: Bool, phase: PlaybackPhase, isBuffering: Bool) -> Bool {
        if hostLoadActive { return true }
        switch phase {
        case .loading, .rebuffering:
            return true
        case .stalled:
            return isBuffering
        case .idle, .playing, .paused, .seeking, .ended, .error:
            return false
        }
    }

    /// Whether the reader is fighting the source right now, i.e. whether the connection chip belongs on
    /// screen. Separate from `showsSpinner` on purpose: the chip is exactly the signal the spinner stopped
    /// carrying, and it stays up across the moment the buffer runs dry.
    static func showsConnectionNotice(hostLoadActive: Bool, phase: PlaybackPhase) -> Bool {
        guard !hostLoadActive else { return false }
        if case .stalled = phase { return true }
        return false
    }
}
