/// The two rules that decide whether the transport is on screen while playback is not running
/// (Sodalite#93). Both used to live inline in `PlayerViewModel` and both were wrong there.
///
/// `hides` is the auto-hide's liveness check, and its whole point is WHERE it is evaluated. The old
/// code checked `isPlaying` when it ARMED the 5s timer, inside `togglePlayPause`, one statement after
/// `player.togglePlayPause()`. That call is asynchronous and the engine's state sink is delivered on a
/// later runloop turn (`.receive(on:)`), so on the very press that paused, `isPlaying` still carried
/// `true`, the guard passed, and five seconds later a paused still frame lost its transport. Asking at
/// FIRE time is the fix; nothing about the answer itself is interesting.
///
/// `raisesTransport` covers the other half: a pause from outside the app (Siri, Control Center, or the
/// AVKit transport that co-owns the hardware play/pause button on the native path) reaches the host only
/// as an engine state change, and that path never touched control visibility at all. It raises the
/// transport now, except in the two states that would misread the flag: behind an error screen the
/// session is over and Menu has to stay "dismiss the player" rather than "close the transport", and the
/// iOS child lock deliberately cleared it. The loading spinner is NOT among them, because it and this
/// decision arrive from different publishers in no fixed order, and a raise skipped on a stale `true`
/// would never be retried.
enum TransportAutoHide {
    /// The idle countdown both auto-hides run on. Five seconds because three hides mid-read on a long
    /// title and ten reads as broken rather than deliberate.
    static let idleDelay: Duration = .seconds(5)

    static func hides(isPlaying: Bool) -> Bool { isPlaying }

    /// The music Now Playing queue's auto-hide (Sodalite#110), asked at FIRE time for the same reason
    /// `hides` is, plus one of its own: `queueHasFocus`. The queue rows are focusable, so a hide that
    /// fired while the user sat on one would delete the focused view and let the focus engine drop the
    /// user somewhere arbitrary. Answering at fire time means the rule sees where focus actually IS,
    /// not where it was five seconds ago. `queueCount > 1` is the same condition the queue column
    /// already draws itself under, restated here so the timer never schedules work for a layout that
    /// is centered anyway.
    static func hidesQueue(isPlaying: Bool, queueCount: Int, queueHasFocus: Bool) -> Bool {
        hides(isPlaying: isPlaying) && queueCount > 1 && !queueHasFocus
    }

    static func raisesTransport(errorVisible: Bool, inputLocked: Bool) -> Bool {
        !errorVisible && !inputLocked
    }
}
