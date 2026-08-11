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

    /// Origin of a burst of backward jumps: the position furthest ahead wins, so three quick presses
    /// keep the place the user actually left instead of the last intermediate landing.
    static func mergedOrigin(_ existing: Double?, _ candidate: Double) -> Double {
        max(existing ?? candidate, candidate)
    }

    static func shouldOpen(pendingOrigin: Double?, targetTime: Double,
                           subtitlesActive: Bool, enabled: Bool) -> Bool {
        guard enabled, !subtitlesActive, let pendingOrigin else { return false }
        return targetTime < pendingOrigin - minimumDistance
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
           let match = bestMatch(streams: streams, language: preferred) {
            return match
        }
        guard let audioLanguage else { return nil }
        return bestMatch(streams: streams, language: audioLanguage)
    }

    private static func bestMatch(streams: [MediaStream], language: String) -> Int? {
        streams
            .filter { $0.type == .subtitle && PlayerViewModel.languagesMatch($0.language, language) }
            .min(by: { PlayerViewModel.subtitleAutoPickRank($0) < PlayerViewModel.subtitleAutoPickRank($1) })?
            .index
    }
}
