/// Highlight cursor for the player's error screen.
///
/// The player has a custom input model: `PlayerHostController` hosts the SwiftUI overlay with
/// `isUserInteractionEnabled = false` on tvOS and drives everything through UIKit press handlers, so a
/// SwiftUI `Button` in the overlay renders but can never take focus. The error screen's buttons were
/// exactly that, decorative, and only Menu ever got the viewer out. Same rule as the track dropdown and
/// the subtitle search: the cursor lives here, the host moves it, the overlay only draws it.
enum PlayerErrorFocus: Equatable, Sendable {
    case retry
    case back

    /// Where the cursor sits when an error appears. Retry is the action the viewer wants when it exists.
    static func initial(hasRetry: Bool) -> PlayerErrorFocus {
        hasRetry ? .retry : .back
    }

    /// One horizontal step. Ends are hard stops rather than a wrap: two buttons wrapping reads as a
    /// cursor that ignored the press.
    func stepped(by direction: Int, hasRetry: Bool) -> PlayerErrorFocus {
        guard hasRetry else { return .back }
        if direction < 0 { return .retry }
        if direction > 0 { return .back }
        return self
    }
}
