import Foundation

/// Queue construction shared by a collection's Play and Shuffle actions.
enum CollectionPlaybackQueue {
    /// Leaf video types only; a nested series or folder has no playable source (Sodalite#53).
    static let playableTypes: Set<ItemType> = [.movie, .episode]

    /// First entry that is not fully watched, or 0 when the collection is finished or empty.
    static func startIndex(playedFlags: [Bool]) -> Int {
        playedFlags.firstIndex(of: false) ?? 0
    }
}
