import Testing
@testable import Sodalite

/// The detail pages' primary action carries the watch state in its label (Sodalite#146), so the
/// three states have to be one decision rather than two functions each re-deriving it.
struct PlayActionStateTests {

    @Test func nothingStartedIsFresh() {
        #expect(PlayActionState.resolve(positionTicks: nil, isPlayed: false) == .fresh)
        #expect(PlayActionState.resolve(positionTicks: 0, isPlayed: false) == .fresh)
    }

    @Test func aPositionIsAResume() {
        #expect(PlayActionState.resolve(positionTicks: 42, isPlayed: false) == .resume)
    }

    @Test func watchedWithoutAPositionIsAReplay() {
        #expect(PlayActionState.resolve(positionTicks: nil, isPlayed: true) == .again)
        #expect(PlayActionState.resolve(positionTicks: 0, isPlayed: true) == .again)
    }

    /// The case the resume capsule had to learn in Sodalite#99: Jellyfin writes "watched" and a new
    /// position together on a re-watch, and an item that is both is being watched NOW. Reading the
    /// flag first would label a re-watch "Play Again" while its own progress bar was filling.
    @Test func watchedAndPartwayAgainIsAResume() {
        #expect(PlayActionState.resolve(positionTicks: 42, isPlayed: true) == .resume)
    }
}
