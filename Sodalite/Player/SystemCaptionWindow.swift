import Foundation
import AetherEngine

/// Sodalite#65, the iOS "Automatic Subtitles > Show when muted" behaviour answered with the app's
/// own subtitles instead of the system's caption box: playing muted switches subtitles on, raising
/// the volume switches them off again.
///
/// The three automatic-caption toggles (muted, skip back, language mismatch) have no read API, so
/// the trigger is what the system DOES with them: it selects a legible option in the player item,
/// which the engine reports as `SystemCaptionRequest`. That signal alone does not say which of the
/// three fired, and the app answers the other two itself (`SkipBackSubtitleWindow`, and the
/// preferred-subtitle settings at load), so the output volume at the moment of the request tells
/// them apart. Reading the volume is only ever used to recognise the mute trigger, never to decide
/// whether the user wants the behaviour: that decision stays with the system setting, which is what
/// makes the request arrive in the first place.
///
/// `PlayerViewModel` owns the wiring; this type owns the decisions so they stay unit-testable
/// without an engine, like `SkipBackSubtitleWindow` and `ForcedSubtitleFallback`.
enum SystemCaptionWindow {
    struct State: Equatable {
        /// The track this window switched on, so closing can never disable a different one.
        var streamIndex: Int
    }

    /// "Muted or very low" is the system's own wording for the trigger, so the band has to be a
    /// little wider than exactly zero.
    static let mutedVolumeCeiling: Float = 0.1

    /// An automatic-caption request opens a window only while the output is muted or very low, and
    /// only when nothing is on screen already: a subtitle the user (or an earlier automatic pick)
    /// chose stays untouched, and a request at normal volume belongs to one of the other two
    /// triggers, which the app answers elsewhere.
    static func shouldOpen(subtitlesActive: Bool, volume: Float) -> Bool {
        guard !subtitlesActive else { return false }
        return volume <= mutedVolumeCeiling
    }

    /// Closes as soon as the output is audible again. The system withdraws its own captions at the
    /// same point, but it cannot tell us so: the engine deselected its option when the request
    /// arrived, so there is no selection left to change back.
    static func shouldClose(state: State?, volume: Float) -> Bool {
        guard state != nil else { return false }
        return volume > mutedVolumeCeiling
    }

    /// The app's own settings decide the language, not the system's pick. iOS resolves the caption
    /// language against its own preferences, which on a German device with English audio still came
    /// out English (device-observed), and someone who set a subtitle language in this app means it
    /// here too. The system's language is kept as the last candidate rather than dropped, so a source
    /// that has nothing in the configured languages still shows what the system asked for.
    ///
    /// `preferredLanguage` is the app's effective audio language, which falls back to the device
    /// locale, so "my language" needs nothing configured to work.
    static func resolveTrack(streams: [MediaStream], requestedLanguage: String?,
                             preferredSubtitleLanguage: String?, preferredLanguage: String?,
                             audioLanguage: String?) -> Int? {
        let candidates = [preferredSubtitleLanguage, preferredLanguage, audioLanguage, requestedLanguage]
        for language in candidates.compactMap({ $0 }) {
            if let match = SkipBackSubtitleWindow.bestSubtitle(streams: streams, language: language) {
                return match
            }
        }
        return nil
    }
}
