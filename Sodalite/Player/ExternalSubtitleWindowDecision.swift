import Foundation

/// Whether the app should take over a wired external display to draw the video plus subtitles itself
/// (Sodalite#98).
///
/// Take it only when a subtitle is selected, an external display is attached, and native subtitle
/// renditions are NOT already reaching it (that stays the DrHurt-confirmed #34 path on an HDR external
/// display), and only while the takeover has not already failed once this session. Pure and platform
/// neutral so the gating is testable without a UIWindow, matching the engine's decision types.
enum ExternalSubtitleWindowDecision {
    static func shouldOwnExternalScreen(
        externalDisplayAttached: Bool, subtitleSelected: Bool,
        nativeRenditionsServed: Bool, handoverFailed: Bool
    ) -> Bool {
        externalDisplayAttached && subtitleSelected && !nativeRenditionsServed && !handoverFailed
    }
}
