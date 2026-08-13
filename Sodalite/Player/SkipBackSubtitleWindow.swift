import Foundation
import AetherEngine

/// Sodalite#63, the tvOS "Automatic subtitles, Show on Skip Back" behaviour: a committed backward
/// jump switches subtitles on at the landing point and off again once playback has caught up with
/// the position the jump started from.
///
/// `PlayerViewModel` owns the wiring (origin capture in `seekJump`, opening in the scrub commits,
/// closing in the clock sink); this type owns the decisions so they stay unit-testable without an
/// engine, like `ForcedSubtitleFallback`.
enum SkipBackSubtitleWindow {
    struct State: Equatable {
        /// Playback position that ends the window, on the same clock as `PlayerViewModel.playbackTime`.
        var origin: Double
        /// The track this window switched on, so closing can never disable a different one.
        var streamIndex: Int
    }

    /// A jump shorter than this is treated as no movement: skipping back at the very start of a file
    /// clamps to zero and would otherwise open a window that closes on the next clock tick.
    private static let minimumDistance: Double = 0.5

    /// The setting this mirrors promises subtitles "when you skip back up to 30 seconds", and a
    /// window lasts until playback has caught up with where the jump started, so an ungated burst of
    /// presses turned subtitles on for minutes. The cap is on the jump the window opens for; the
    /// merge path deliberately keeps an already open window when more presses follow, because those
    /// are the same catch-up, and `cappedOrigin` keeps even that within the promised 30 seconds.
    /// 30 s is also the largest single press the app offers (`skipIntervalChoices`), so one press
    /// always qualifies.
    static let maximumDistance: Double = 30

    /// Tolerates the rounding between a press interval and the position the seek actually lands on,
    /// so a 30 s press is not gated out by a few milliseconds.
    private static let distanceTolerance: Double = 0.5

    /// Origin of a burst of backward jumps: the position furthest ahead wins, so three quick presses
    /// keep the place the user actually left instead of the last intermediate landing.
    static func mergedOrigin(_ existing: Double?, _ candidate: Double) -> Double {
        max(existing ?? candidate, candidate)
    }

    static func shouldOpen(pendingOrigin: Double?, targetTime: Double,
                           subtitlesActive: Bool, enabled: Bool) -> Bool {
        guard enabled, !subtitlesActive, let pendingOrigin else { return false }
        let distance = pendingOrigin - targetTime
        return distance > minimumDistance && distance <= maximumDistance + distanceTolerance
    }

    /// Ends a window at most `maximumDistance` after the position it opened at, whatever the origin
    /// says. A burst of presses commits as one jump on tvOS but as several on iOS, where each one
    /// merges into the open window and pushes its end further out; without this, the two platforms
    /// would promise different things for the same three presses.
    static func cappedOrigin(_ origin: Double, targetTime: Double) -> Double {
        min(origin, targetTime + maximumDistance)
    }

    static func shouldClose(state: State?, playhead: Double) -> Bool {
        guard let state else { return false }
        return playhead >= state.origin
    }

    /// Preferred subtitle language first, then the language being heard. A preferred language with no
    /// matching track falls through rather than giving up: the point of the window is reading back the
    /// dialogue that just played. Nothing matching resolves to nil, never to an arbitrary first track.
    static func resolveTrack(streams: [MediaStream], preferredSubtitleLanguage: String?,
                             audioLanguage: String?) -> Int? {
        if let preferred = preferredSubtitleLanguage,
           let match = bestSubtitle(streams: streams, language: preferred) {
            return match
        }
        guard let audioLanguage else { return nil }
        return bestSubtitle(streams: streams, language: audioLanguage)
    }

    /// Shared with `SystemCaptionWindow`, which resolves the language the system picked the same way.
    static func bestSubtitle(streams: [MediaStream], language: String) -> Int? {
        streams
            .filter { $0.type == .subtitle && PlayerViewModel.languagesMatch($0.language, language) }
            .min(by: { PlayerViewModel.subtitleAutoPickRank($0) < PlayerViewModel.subtitleAutoPickRank($1) })?
            .index
    }
}
