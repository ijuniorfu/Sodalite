import Foundation

/// Grey levels the app and the Top Shelf extension have to agree on. The extension draws with Core
/// Graphics and has no SwiftUI import, so the number lives here as a plain `Double` and each side
/// wraps it in its own colour type: `Color.Theme` on the app side, `CGColor` in `ResumeBarRenderer`.
///
/// `nonisolated` for the same reason as `TopShelfAccent`: the app targets default to MainActor
/// isolation, the extension defaults to nonisolated, and both compile this file.
enum NeutralLevel {
    /// Resume-progress track. Opaque, and neither a material nor a translucent black. Both of those
    /// let the artwork through, so on a bright still the track ends up as light as the fill and the
    /// played part stops being readable: measured on a bright backdrop, white-at-30% put fill and
    /// track at 183 vs 115 luma (1.54:1), while this level puts them at 183 vs 44 (3.46:1).
    ///
    /// One number, because the shelf's bar and the app's bar sit on the same artwork and used to
    /// carry a copy each, with only a comment on either side claiming they matched (Sodalite#106).
    nonisolated static let resumeTrack = 0.13
}
