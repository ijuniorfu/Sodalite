import Foundation
import Testing
@testable import Sodalite

@Suite("Collection playback queue")
struct CollectionPlaybackQueueTests {

    @Test("starts at the first unwatched entry")
    func firstUnwatched() {
        #expect(CollectionPlaybackQueue.startIndex(playedFlags: [true, true, false, false]) == 2)
        #expect(CollectionPlaybackQueue.startIndex(playedFlags: [false, false, false]) == 0)
    }

    /// A gap in the middle wins over a later unwatched entry: the collection is ordered, so the
    /// earliest unfinished film is the one to continue with.
    @Test("an earlier gap wins over a later one")
    func earliestGap() {
        #expect(CollectionPlaybackQueue.startIndex(playedFlags: [true, false, true, false]) == 1)
    }

    /// Rewatching a finished collection starts over rather than dead-ending.
    @Test("fully watched restarts at the top")
    func allWatched() {
        #expect(CollectionPlaybackQueue.startIndex(playedFlags: [true, true, true]) == 0)
    }

    @Test("empty list yields index zero")
    func empty() {
        #expect(CollectionPlaybackQueue.startIndex(playedFlags: []) == 0)
    }

    /// Nested series and folders cannot seed a queue entry the player has no source for.
    @Test("only leaf video types are playable")
    func playableTypes() {
        #expect(CollectionPlaybackQueue.playableTypes.contains(.movie))
        #expect(CollectionPlaybackQueue.playableTypes.contains(.episode))
        #expect(CollectionPlaybackQueue.playableTypes.contains(.series) == false)
        #expect(CollectionPlaybackQueue.playableTypes.contains(.boxSet) == false)
    }
}
