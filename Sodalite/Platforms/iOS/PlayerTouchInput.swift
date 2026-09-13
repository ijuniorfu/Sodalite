import CoreGraphics

/// Pure gesture-to-intent mappers for the iOS touch player, shared by the SwiftUI gesture catcher
/// and unit tests. The actual gestures live in SwiftUI (PlayerGestureCatcher) so they sit in the
/// overlay's z-order below the controls and above the video, avoiding a UIKit/SwiftUI hit-test fight.
enum PlayerTouchInput {
    /// Left third -> -1, right third -> +1, middle -> nil (handled as play/pause). Sodalite#144 took
    /// the length back out of here: the tap says which way, the preferences say how far, and since the
    /// two directions can differ a single `interval` argument could only have been wrong one way.
    static func skipDirection(forTapX x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0 else { return nil }
        if x < width / 3 { return -1 }
        if x > width * 2 / 3 { return 1 }
        return nil
    }

    /// Upward drag raises the level. Returned delta is a 0...1-scaled fraction of the drag height.
    static func levelDelta(translationY: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double(-translationY / height)
    }
}
