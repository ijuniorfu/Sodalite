import Foundation

/// Pure decision logic for the next-episode flow: when the end-window opens, and where end-of-media
/// routes. Kept engine- and UIKit-free so the state machine is unit-testable without a running session,
/// mirroring PlayerLockProgress. Both call sites live in PlayerViewModel's Combine sinks.
enum NextEpisodePolicy {

    /// How far from the end the overlay opens when the server has no outro marker.
    static let fallbackWindowSeconds: Double = 30

    /// True while the playhead sits in the window that shows the overlay and arms the countdown.
    ///
    /// Single definition on purpose: the clock sink, `checkForNextEpisode`, and the cancel-latch reset
    /// must agree on the window, else a cancel taken inside it can never be released.
    /// `sourceTime` is the absolute source-timeline value (outro markers are source-relative), while
    /// `remainingSeconds` is measured on the presentation clock.
    static func isInsideTriggerWindow(
        outroStartSeconds: Double?,
        sourceTime: Double,
        remainingSeconds: Double
    ) -> Bool {
        // With a marker, the credits define the window; the fallback deliberately does not apply, a
        // short outro would otherwise open the overlay ahead of the credits it was measured for.
        if let outroStartSeconds { return sourceTime >= outroStartSeconds }
        return remainingSeconds < fallbackWindowSeconds
    }

    /// What the session does when the engine reports end-of-media.
    enum EndOfPlaybackOutcome: Equatable {
        /// Someone else owns the transition (countdown already running, overlay already parked), or
        /// playback never produced a frame.
        case ignore
        /// Close the PiP window and end the session rather than parking a black frame in the corner.
        case endPictureInPicture
        /// Show the overlay and start the auto-advance countdown.
        case showOverlayAndAdvance
        /// Nothing follows: close the player, same as a movie reaching its end.
        case dismissPlayer
    }

    /// Routes end-of-media. Exhaustive by construction: the earlier inline chain had a hole for a
    /// cancelled advance (next episode known, user rejected it), which matched no branch and left the
    /// player open on a terminal `.ended` engine session where seek and play are both no-ops.
    static func endOfPlaybackOutcome(
        hasStartedPlaying: Bool,
        pictureInPictureActive: Bool,
        pictureInPictureCanAdvance: Bool,
        hasNextEpisode: Bool,
        advanceCancelled: Bool,
        countdownRunning: Bool,
        overlayVisible: Bool
    ) -> EndOfPlaybackOutcome {
        guard hasStartedPlaying else { return .ignore }

        // A rejected advance is "no successor for this session", so it routes like end-of-content.
        let willAdvance = hasNextEpisode && !advanceCancelled

        if pictureInPictureActive {
            // In-place item handover keeps the window alive (native backend); every other case ends it.
            guard willAdvance, pictureInPictureCanAdvance else { return .endPictureInPicture }
        }
        if willAdvance {
            return countdownRunning ? .ignore : .showOverlayAndAdvance
        }
        // A visible overlay (queue exhausted, manual pick still offered) keeps the player up.
        return overlayVisible ? .ignore : .dismissPlayer
    }
}
