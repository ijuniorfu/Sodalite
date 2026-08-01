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
    static func primaryBottomInset(reservesHint: Bool) -> CGFloat {
        reservesHint ? 64 : 24
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
