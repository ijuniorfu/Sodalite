import Foundation

/// Run `work` on the next main-queue turn (not `Task.sleep`) for `@FocusState` writes that must land *after* the current focus-engine commit. `Task.sleep`'s cooperative-thread resume can land back inside the same commit it meant to dodge (tvOS, remote-press-driven focus update); `asyncAfter` always lands on a fresh turn. Default 0.05 s is the smallest reliable delay for focus-write sites; callers chasing a scroll animation pass their own.
@inlinable
func deferOnMain(by delay: TimeInterval = 0.05, _ work: @escaping @MainActor () -> Void) {
    // assumeIsolated is correct by construction: closure is @MainActor (so Sendable) and the main queue is the MainActor's executor.
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        MainActor.assumeIsolated { work() }
    }
}
