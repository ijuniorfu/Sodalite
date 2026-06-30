import AetherEngine

/// Single rule for the player's loading spinner (`PlayerViewModel.isLoading`).
///
/// The spinner shows while either the host is still bringing a session up (`hostLoadActive`: fetching
/// playback info, calling `player.load()`, or running a live retune) or the engine's `playbackPhase`
/// reports startup / mid-stream work. Adopting `playbackPhase` is what lets a mid-stream rebuffer or a
/// source stall / reconnect (429 / 503) raise the spinner instead of freezing on the last frame
/// (AetherEngine#85); the old code only watched `state` transitions and never saw `isBuffering`.
///
/// `.seeking` is owned by the scrub UI, so it never raises the spinner here. The live cold-transcode
/// debounce (a premature first `.playing`) is a timing concern handled by `PlayerViewModel`, not this rule.
enum PlayerLoadingIndicator {
    static func showsSpinner(hostLoadActive: Bool, phase: PlaybackPhase) -> Bool {
        if hostLoadActive { return true }
        switch phase {
        case .loading, .rebuffering, .stalled:
            return true
        case .idle, .playing, .paused, .seeking, .ended, .error:
            return false
        }
    }
}
