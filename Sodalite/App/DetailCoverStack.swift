import SwiftUI

/// Whether anything is pushed inside a `detailCover`'s NavigationStack, so the cover can drop its
/// close button while a back button is on screen (Sodalite discussion #98, point 5).
///
/// The X dismisses the whole cover. On a page opened straight from Home that is exactly "close this
/// page", but a library grid is itself a cover, so on a title reached through one the X skips the
/// grid and lands on Home while the arrow beside it goes back one step. Two buttons, one of which
/// silently means something else, so the X stands down while the arrow is there.
///
/// A SET of tokens, not a counter: the appear/disappear pair that brackets a push does not arrive in
/// a fixed order (a stack raises the incoming page's appear before the covered page's disappear, and
/// on a pop the reappearing page's appear before the popped page's disappear). A set is insensitive
/// to that order, cannot be double-counted by a page whose appear fires twice, and cannot be driven
/// negative by a disappear whose appear it never saw.
@MainActor
@Observable
final class DetailCoverStack {

    /// Identity of one pushed page, owned by that page for as long as it is in the stack.
    struct Token: Hashable {
        private let id = UUID()
    }

    private var pushed: Set<Token> = []

    /// True while at least one page sits above the cover's root.
    var isPushed: Bool { !pushed.isEmpty }

    func enter(_ token: Token) { pushed.insert(token) }
    func leave(_ token: Token) { pushed.remove(token) }
}

/// nil outside a `detailCover`, which is what makes `.detailCoverPush()` free to apply to any
/// navigation destination without asking where it is being presented from.
private struct DetailCoverStackKey: EnvironmentKey {
    static let defaultValue: DetailCoverStack? = nil
}

extension EnvironmentValues {
    var detailCoverStack: DetailCoverStack? {
        get { self[DetailCoverStackKey.self] }
        set { self[DetailCoverStackKey.self] = newValue }
    }
}

/// Marks a navigation destination as sitting above a `detailCover`'s root, so the cover hides its
/// close button while this page is on screen. A no-op outside a cover.
///
/// Applied at the push site rather than inside the pushed screens: the same screens (a detail router,
/// a person page) are also used AS a cover's root, where the close button is the only way out.
private struct DetailCoverPush: ViewModifier {
    @Environment(\.detailCoverStack) private var stack
    @State private var token = DetailCoverStack.Token()

    func body(content: Content) -> some View {
        content
            .onAppear { stack?.enter(token) }
            .onDisappear { stack?.leave(token) }
    }
}

extension View {
    func detailCoverPush() -> some View {
        modifier(DetailCoverPush())
    }
}
