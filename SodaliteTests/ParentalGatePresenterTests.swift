import Foundation
import Testing
@testable import Sodalite

/// The PIN cover lives on the AppRouter, but on iOS the Settings sheet is presented from inside it
/// and both share one hosting controller. A cover cannot stack on that sheet, so the router's
/// presentation is swallowed and `challenge` never resolves: the button looks dead until the sheet
/// closes. Whoever is innermost has to present, which is what this stack decides.
@Suite("Which host puts the Guardian-PIN cover on screen")
@MainActor
struct ParentalGatePresenterTests {

    @Test func theRouterPresentsWhileNoInnerHostIsOnScreen() {
        let gate = ParentalGate()
        #expect(gate.presenterStack.isEmpty)
    }

    @Test func aSheetTakesOverThePresentationWhileItIsUp() {
        let gate = ParentalGate()
        let sheet = "settings.sheet"
        gate.pushPresenter(sheet)
        #expect(gate.presenterStack.last == sheet)

        gate.popPresenter(sheet)
        #expect(gate.presenterStack.isEmpty)
    }

    /// Nested sheets: the innermost one is the only one that can present.
    @Test func theInnermostHostWins() {
        let gate = ParentalGate()
        let outer = "profile.cover"
        let inner = "settings.sheet"
        gate.pushPresenter(outer)
        gate.pushPresenter(inner)
        #expect(gate.presenterStack.last == inner)

        gate.popPresenter(inner)
        #expect(gate.presenterStack.last == outer)
    }

    /// The claim is pushed from onAppear and released again from the presenting side, so both can
    /// fire more than once. A host must not sit in the stack twice, else a single pop leaves a dead
    /// presenter on top and every later challenge hangs with nothing on screen.
    @Test func aHostIsRegisteredOnceNoMatterHowOftenItAppears() {
        let gate = ParentalGate()
        let sheet = "settings.sheet"
        gate.pushPresenter(sheet)
        gate.pushPresenter(sheet)
        #expect(gate.presenterStack == [sheet])

        gate.popPresenter(sheet)
        #expect(gate.presenterStack.isEmpty)
        gate.popPresenter(sheet)
        #expect(gate.presenterStack.isEmpty)
    }

    /// A challenge left unanswered by a host that went away resolves as a cancel rather than
    /// leaking the continuation into the next one.
    @Test func aSecondChallengeFailsTheFirstInsteadOfLeakingIt() async {
        let gate = ParentalGate()
        let first = Task { await gate.challenge(reason: .logout) }
        while gate.activeRequest == nil { await Task.yield() }

        let second = Task { await gate.challenge(reason: .serverManagement) }
        #expect(await first.value == false)

        while gate.activeRequest?.reason != .serverManagement { await Task.yield() }
        gate.resolve(true)
        #expect(await second.value == true)
    }
}
