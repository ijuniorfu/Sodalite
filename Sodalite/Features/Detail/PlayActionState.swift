import Foundation

/// What the detail pages' primary action is actually doing, resolved from the item it will start
/// (Sodalite#146). The label carries the watch state, so the label and the subtitle have to read one
/// decision: they used to be two functions deriving it separately, and the version that names the
/// episode in the label would otherwise keep repeating it underneath.
enum PlayActionState: Equatable {
    /// Never started.
    case fresh
    /// Carries a resume position.
    case resume
    /// Watched through, with no resume position left.
    case again

    /// The position is what decides, not the watched flag. Jellyfin writes "watched" and a new
    /// position together on a re-watch (the same middle branch of `UpdatePlayState` the resume
    /// capsule had to learn about in Sodalite#99), so an item that is both is being watched now.
    static func resolve(positionTicks: Int64?, isPlayed: Bool) -> PlayActionState {
        if (positionTicks ?? 0) > 0 { return .resume }
        return isPlayed ? .again : .fresh
    }
}
