import Testing
@testable import Sodalite

/// The error screen's cursor. It exists because the player's SwiftUI overlay is display-only on tvOS, so
/// a `Button` there is never focusable and the "Back" button on every player error was decorative.
struct PlayerErrorFocusTests {

    @Test func retryIsWhereTheCursorStartsWhenItExists() {
        #expect(PlayerErrorFocus.initial(hasRetry: true) == .retry)
    }

    @Test func withoutARetryTheCursorStartsOnBack() {
        #expect(PlayerErrorFocus.initial(hasRetry: false) == .back)
    }

    @Test func rightMovesToBackAndLeftMovesToRetry() {
        #expect(PlayerErrorFocus.retry.stepped(by: 1, hasRetry: true) == .back)
        #expect(PlayerErrorFocus.back.stepped(by: -1, hasRetry: true) == .retry)
    }

    @Test func endsAreHardStops() {
        #expect(PlayerErrorFocus.back.stepped(by: 1, hasRetry: true) == .back)
        #expect(PlayerErrorFocus.retry.stepped(by: -1, hasRetry: true) == .retry)
    }

    /// Every other player error (playback stopped, channel unavailable, a failed start) has one button, so
    /// horizontal presses must not park the cursor on a retry that is not on screen.
    @Test func withoutARetryEveryStepStaysOnBack() {
        #expect(PlayerErrorFocus.back.stepped(by: -1, hasRetry: false) == .back)
        #expect(PlayerErrorFocus.back.stepped(by: 1, hasRetry: false) == .back)
        #expect(PlayerErrorFocus.retry.stepped(by: -1, hasRetry: false) == .back)
    }
}
