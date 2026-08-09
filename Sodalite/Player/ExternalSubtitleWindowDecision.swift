import Foundation

/// Whether the app should take over a wired external display to draw the video plus subtitles itself
/// (Sodalite#98).
///
/// Take it whenever a subtitle is selected and an external display is attached, and only while the
/// takeover has not already failed once this session. Pure and platform neutral so the gating is
/// testable without a UIWindow, matching the engine's decision types.
///
/// The engine's serving state (`nativeSubtitleRenditionsServed`) used to gate this: a served master
/// playlist was read as proof that AVKit renders its WebVTT renditions on the external screen, so the
/// takeover stood down. DrHurt's 2026-08-09 matrix (Sodalite#34) disproves that premise in every
/// configuration it covers. Master is served for SDR content on any panel and for HDR content on an
/// HDR panel, media only for HDR on an SDR panel, and subtitles reached the external screen in exactly
/// that one media case, the only one where the takeover was allowed to run. So the flag is a playlist
/// property, never a statement about what the external screen shows, and it is not read here any more.
enum ExternalSubtitleWindowDecision {
    static func shouldOwnExternalScreen(
        externalDisplayAttached: Bool, subtitleSelected: Bool, handoverFailed: Bool
    ) -> Bool {
        externalDisplayAttached && subtitleSelected && !handoverFailed
    }
}
