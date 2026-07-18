import Foundation

/// Pure hold-to-unlock progress math for the iOS player child lock, shared by PlayerLockOverlay and
/// unit tests. Kept UIKit-free (and cross-platform, so the tvOS-hosted test target can reach it) so
/// the timing logic is testable without a running gesture, mirroring PlayerTouchInput. The child lock
/// disables all touch input; a full hold of `holdDuration` releases it.
enum PlayerLockProgress {
    /// Default hold length to release the lock, in seconds.
    static let holdDuration: Double = 2.0

    /// Fraction of the required hold completed, clamped to 0...1. `duration` must be > 0.
    static func fraction(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    /// Release fires only on a full hold.
    static func isComplete(_ fraction: Double) -> Bool {
        fraction >= 1.0
    }
}
