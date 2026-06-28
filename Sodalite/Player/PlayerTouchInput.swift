#if os(iOS)
import CoreGraphics

/// Pure gesture-to-intent mappers for the iOS touch player, shared by the SwiftUI gesture catcher
/// and unit tests. The actual gestures live in SwiftUI (PlayerGestureCatcher) so they sit in the
/// overlay's z-order below the controls and above the video, avoiding a UIKit/SwiftUI hit-test fight.
enum PlayerTouchInput {
    /// Left third -> -interval, right third -> +interval, middle -> nil (handled as play/pause).
    static func skipSeconds(forTapX x: CGFloat, width: CGFloat, interval: Double) -> Double? {
        guard width > 0 else { return nil }
        if x < width / 3 { return -interval }
        if x > width * 2 / 3 { return interval }
        return nil
    }

    /// Upward drag raises the level. Returned delta is a 0...1-scaled fraction of the drag height.
    static func levelDelta(translationY: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double(-translationY / height)
    }
}
#endif
