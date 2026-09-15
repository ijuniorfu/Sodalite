import SwiftUI

/// Visibility rules for the tvOS fold marker on detail pages.
enum ScrollHintPolicy {
    /// Any real scroll hides the hint; 8pt absorbs focus-engine jitter at rest.
    static let hideThreshold: CGFloat = 8

    static func isVisible(scrollOffset: CGFloat, belowFoldHeight: CGFloat, hasSettled: Bool) -> Bool {
        hasSettled && belowFoldHeight > 0 && scrollOffset < hideThreshold
    }

    /// Bottom inset of the first page's primary block. The wider tvOS band holds the chevron and
    /// stays reserved while it is hidden, so fading it out never moves the button row.
    ///
    /// It also has a second job, and that is what set its value (Sodalite#146 round 2). tvOS parks a
    /// focused control about 180 pt above the bottom edge, and Play is focused the moment a detail
    /// page opens. At 64 that request was not met, so the focus engine scrolled the page down by the
    /// difference as soon as it could: measured on a device, twice, the page came to rest at exactly
    /// 116 pt, which is 180 less 64. Gating the room it scrolled into only changed WHEN it did,
    /// because the engine takes it the moment it appears.
    ///
    /// So the band is the parking distance now. Meeting the request at rest is what leaves the
    /// engine nothing to do, and the fold stays on the viewport edge where the page put it.
    static func primaryBottomInset(reservesHint: Bool) -> CGFloat {
        reservesHint ? focusParkingDistance : 24
    }

    /// What tvOS wants below a focused control. Measured rather than documented by Apple: the same
    /// number turns up in `DetailContentOverlay.trailingFiller`, where it decides how much trailing
    /// space the last row needs to land where every other row lands.
    static let focusParkingDistance: CGFloat = 180

    /// Where the chevron sits inside that band. It marks the fold, but it belongs to the block above
    /// it: parked at the band's own bottom edge it would sit 170 pt clear of the buttons and read as
    /// a stray glyph at the screen edge rather than as this page's "there is more". 54 pt under the
    /// action row is where it sat when the band was 64.
    static func hintBottomInset(reservesHint: Bool) -> CGFloat {
        primaryBottomInset(reservesHint: reservesHint) - 54
    }
}

/// Fold marker for tvOS detail pages: a floating chevron centered under the action row.
///
/// White rather than accent-tinted: five of the 23 accents (indigo, royalViolet, ultraviolet,
/// burgundy, cobalt) sit between 2.1:1 and 2.9:1 against the dark scrim, unreadable for a thin
/// glyph at couch distance. White's only weak case is a bright backdrop, which the 0.55 scrim
/// plus the shadow covers.
struct ScrollHintChevron: View {
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false

    var body: some View {
        Image(systemName: "chevron.compact.down")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 6)
            .offset(y: lifted ? 5 : -5)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: isVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // Drive the float off visibility, not onAppear: a repeatForever animation left running
            // behind a hidden view keeps the display link awake on every detail page.
            .onChange(of: isVisible, initial: true) { _, visible in
                guard !reduceMotion else {
                    lifted = false
                    return
                }
                if visible {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        lifted = true
                    }
                } else {
                    withAnimation(.linear(duration: 0)) { lifted = false }
                }
            }
    }
}
