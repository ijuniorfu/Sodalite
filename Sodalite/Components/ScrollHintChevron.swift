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
