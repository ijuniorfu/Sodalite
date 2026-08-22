import Testing
import Foundation
@testable import Sodalite

/// `ErrorText` decides which of three things a viewer reads. The interesting case is the third, because
/// it is the one that used to ship a Swift type name into a 26-language app.
@MainActor
struct ErrorTextTests {

    struct Bare: Error {}

    struct Described: LocalizedError {
        var errorDescription: String? { "A sentence the type wrote itself" }
    }

    struct Blank: LocalizedError {
        var errorDescription: String? { "" }
    }

    /// The measurement the classification rests on, kept as a test rather than as a comment: Foundation
    /// builds the domain of a bridged Swift error from its fully qualified type name, so it carries the
    /// module separator, and no system domain does.
    @Test func aBridgedSwiftErrorIsTellableFromASystemErrorByItsDomain() {
        #expect((Bare() as NSError).domain.contains("."))
        #expect(!(URLError(.timedOut) as NSError).domain.contains("."))
        #expect((URLError(.timedOut) as NSError).domain == NSURLErrorDomain)
    }

    /// The failure that started this: without a description the bridge renders the type's own name.
    @Test func aTypeWithNoDescriptionWouldOtherwiseNameItselfAtTheViewer() {
        #expect(Bare().localizedDescription.contains("Bare"))
        #expect(!ErrorText.user(for: Bare()).contains("Bare"))
        #expect(ErrorText.user(for: Bare()) == ErrorText.unexpected)
    }

    @Test func aTypeThatDescribesItselfIsTakenAtItsWord() {
        #expect(ErrorText.user(for: Described()) == "A sentence the type wrote itself")
    }

    /// An empty description is not a description; it would paint a blank error card.
    @Test func anEmptyDescriptionFallsThroughRatherThanPaintingNothing() {
        #expect(ErrorText.user(for: Blank()) == ErrorText.unexpected)
    }

    /// System errors keep their own text: the OS translates those, and they say more than a generic line.
    @Test func aSystemErrorKeepsTheSentenceTheSystemLocalized() {
        let system = URLError(.timedOut)
        #expect(ErrorText.user(for: system) == system.localizedDescription)
        #expect(ErrorText.user(for: system) != ErrorText.unexpected)
    }

    /// Every error type the app declares answers through this path, so spot-check the ones that reach a
    /// viewer on the profile and server screens.
    @Test func theAppsOwnTypesAnswerWithTheirOwnCopy() {
        #expect(ErrorText.user(for: APIError.timeout) == APIError.timeout.errorDescription)
        #expect(!ErrorText.user(for: DependencyContainer.ServerSwitchError.unknown).contains("ServerSwitchError"))
        #expect(!ErrorText.user(for: KeychainError.loadFailed(-25300)).contains("KeychainError"))
        #expect(ErrorText.user(for: KeychainError.loadFailed(-25300)).contains("-25300"))
        #expect(!ErrorText.user(for: StoreKitServiceError.verificationFailed).contains("StoreKitServiceError"))
    }
}
