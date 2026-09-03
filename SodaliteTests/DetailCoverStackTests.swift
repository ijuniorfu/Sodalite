import Testing
@testable import Sodalite

/// The detail cover's close button and the pushed page's back button both claim the top of the
/// screen, and the X means something different from the arrow: it dismisses the whole cover, so on a
/// page reached from a library grid it jumps past the grid to Home (Sodalite discussion #98, point 5).
/// The X is therefore hidden while anything is pushed, which turns on knowing whether anything is.
///
/// Depth is a SET of tokens rather than a counter because the two events that bracket a push do not
/// arrive in one order. A NavigationStack raises the incoming page's appear before the covered page's
/// disappear on a push, and the reappearing page's appear before the popped page's disappear on a
/// pop. A counter survives both, but only as long as every increment is matched; a token cannot
/// double-count a page whose appear fires twice, and cannot be driven negative by a stray disappear.
@MainActor
struct DetailCoverStackTests {

    @Test("A cover with nothing pushed shows its close button")
    func rootShowsClose() {
        let stack = DetailCoverStack()
        #expect(stack.isPushed == false)
    }

    @Test("A pushed page hides the close button")
    func pushHidesClose() {
        let stack = DetailCoverStack()
        let page = DetailCoverStack.Token()
        stack.enter(page)
        #expect(stack.isPushed)
        stack.leave(page)
        #expect(stack.isPushed == false)
    }

    /// Push: the incoming page appears before the covered one disappears.
    @Test("The button stays hidden across a push, in the order the stack reports it")
    func pushOrder() {
        let stack = DetailCoverStack()
        let first = DetailCoverStack.Token(), second = DetailCoverStack.Token()
        stack.enter(first)
        stack.enter(second)          // incoming appears
        stack.leave(first)           // covered one disappears, after
        #expect(stack.isPushed)
    }

    /// Pop: the reappearing page appears before the popped one disappears.
    @Test("The button stays hidden across a pop, in the order the stack reports it")
    func popOrder() {
        let stack = DetailCoverStack()
        let first = DetailCoverStack.Token(), second = DetailCoverStack.Token()
        stack.enter(first)
        stack.enter(second)
        stack.leave(first)
        stack.enter(first)           // uncovered page reappears
        stack.leave(second)          // popped page disappears, after
        #expect(stack.isPushed)
    }

    @Test("Popping the last page brings the close button back")
    func popToRoot() {
        let stack = DetailCoverStack()
        let page = DetailCoverStack.Token()
        stack.enter(page)
        stack.leave(page)
        #expect(stack.isPushed == false)
    }

    /// A page whose appear fires twice without an intervening disappear must not need two leaves.
    @Test("A repeated appear does not double-count the same page")
    func repeatedEnterIsIdempotent() {
        let stack = DetailCoverStack()
        let page = DetailCoverStack.Token()
        stack.enter(page)
        stack.enter(page)
        stack.leave(page)
        #expect(stack.isPushed == false)
    }

    /// A disappear with no matching appear (a teardown that outlives its page) must not underflow
    /// into a state where a later real push cannot be seen.
    @Test("An unmatched disappear cannot drive the stack below its root")
    func strayLeaveIsHarmless() {
        let stack = DetailCoverStack()
        stack.leave(DetailCoverStack.Token())
        #expect(stack.isPushed == false)
        let page = DetailCoverStack.Token()
        stack.enter(page)
        #expect(stack.isPushed)
    }

    @Test("Two pages pushed in sequence both have to leave before the button returns")
    func bothMustLeave() {
        let stack = DetailCoverStack()
        let first = DetailCoverStack.Token(), second = DetailCoverStack.Token()
        stack.enter(first)
        stack.enter(second)
        stack.leave(second)
        #expect(stack.isPushed)
        stack.leave(first)
        #expect(stack.isPushed == false)
    }
}
