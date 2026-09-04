import SwiftUI

/// The app's neutral palette. Chromatic colour is the accent system's job (`AppearanceTheme.swift`);
/// everything here is a grey, a dim or a system status colour, and none of it follows the tint.
///
/// A token is named for the ROLE it plays, not for its value, because several roles share a number
/// today and would not survive a retune together. In particular these tokens are for FLAT SURFACES
/// only. A `.shadow(color:)` is not a scrim and a gradient stop is not a fill: both are tuned
/// against what they sit on (subtitle text over video, the hero mark over artwork, the resume label
/// over a bright still) and several carry a measurement in a comment at the call site. Folding those
/// into a shared token would let one retune quietly undo the measurement (Sodalite#106).
extension Color {
    enum Theme {
        // MARK: Surfaces

        /// Neutral card / tile / poster-placeholder ground.
        static let surface = Color(white: 0.1)
        /// Raised neutral surface (focused guide cells, elevated sheets).
        static let surfaceElevated = Color(white: 0.15)
        /// Resume-progress track, shared with the Top Shelf renderer. See ``NeutralLevel/resumeTrack``.
        static let resumeTrack = Color(white: NeutralLevel.resumeTrack)

        // MARK: Row and chip fills
        //
        // Two families, distinguished by what the focused state does. Where FOCUS goes white, the
        // resting ground is dark (`restFill` / `restFillFaint`) and focus lifts it to `focusFill`.
        // Where focus goes to the tint, the resting ground is brighter (`restFillStrong`), because
        // the lift comes from the colour rather than from the level. Reading `restFillStrong` as a
        // drifted `focusFill` is the mistake to avoid, they belong to different controls.

        /// Focused ground of a control whose focus state is white.
        static let focusFill = Color.white.opacity(0.15)
        /// Resting ground of a control whose focus state is the tint.
        static let restFillStrong = Color.white.opacity(0.12)
        /// Resting or selected ground of a control whose focus state is white; also the static
        /// ground of a chip or panel that does not take focus at all.
        static let restFill = Color.white.opacity(0.08)
        /// Faintest resting ground, for a row nested inside an already lifted surface.
        static let restFillFaint = Color.white.opacity(0.04)

        // MARK: Strokes

        /// 1pt outline on a control that is not focused (transport buttons, accent swatches,
        /// poster badges). Only the dominant value is tokenised; the codebase also carries
        /// outlines at 0.08, 0.12, 0.15 and 0.16 that nobody has picked between yet.
        static let hairline = Color.white.opacity(0.18)

        // MARK: Scrims
        //
        // Flat, full-surface dims only. Not shadows, not gradient stops.

        /// Panel and content-block scrim under body copy.
        static let scrim = Color.black.opacity(0.55)
        /// Heavy dim behind a sheet or an expanded panel. The parental-control covers sit deliberately
        /// higher (0.92 / 0.95) and keep their own literal.
        static let scrimHeavy = Color.black.opacity(0.85)

        // MARK: Status
        //
        // Error TEXT keeps plain `.red`: that is SwiftUI's own semantic for it and a token adds a
        // name without adding a decision. The two domain status switches (`SeerrMediaStatus.color`,
        // `SupportDevelopmentView`'s banner tint) are already single-definition palettes and stay
        // whole; pulling one case out of a six-case switch would scatter it, not centralise it.

        /// Available, verified, finished.
        static let success = Color.green
        /// The fill of a destructive action, and the trash glyph that opens one.
        static let destructive = Color.red
        /// Recording in progress, and the timer dot that promises one.
        static let recording = Color.red
    }
}
