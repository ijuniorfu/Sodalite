import Foundation

/// Which position a stop report carries, which is what decides whether Jellyfin files the episode as
/// watched or leaves it in Continue Watching.
///
/// Jellyfin marks an item played from the reported position alone: past `MaxResumePct` (90 by default)
/// it sets `Played` and clears the resume point, at or below it stores the position and the item stays
/// on the shelf. Measured against a live server on 2026-08-22: a stop at 91% marks it, 90% does not.
///
/// That threshold is the whole bug. The next-episode flow opens on the OUTRO MARKER, which on a show
/// with minutes of credits sits well under 90%, so an episode watched to the end and advanced away from
/// reported the marker's position and stayed in Continue Watching, with a bar nearly full. Leaving by
/// hand during the credits lands in the same place. In both cases the viewer is done with the episode
/// and the app knows it, so the report says so instead of describing where the playhead happened to be.
enum PlaybackCompletionReport {

    /// The position to report on stop. `reachedEndOfContent` is the same end-window the next-episode
    /// overlay opens on (`NextEpisodePolicy.isInsideTriggerWindow`), shared rather than re-derived so
    /// the two cannot disagree about when an episode is over.
    ///
    /// Without a runtime there is nothing to round up to, and nothing for Jellyfin to compare against
    /// either, so the playhead stands. Never rounds DOWN: a playhead already past the runtime (a
    /// container whose duration undershoots) is left alone.
    static func positionTicks(
        playhead: Int64,
        runtimeTicks: Int64?,
        reachedEndOfContent: Bool
    ) -> Int64 {
        guard reachedEndOfContent, let runtimeTicks, runtimeTicks > 0 else { return playhead }
        return max(playhead, runtimeTicks)
    }
}
