import Testing
import UIKit
import AetherEngine
@testable import Sodalite

/// Mapping from the engine's typed `PlaybackErrorInfo` (AetherEngine#376/#377/#378) onto the host's
/// error faces. Split from the copy on purpose: the classification is testable without a locale, the
/// sentences are not.
struct PlayerEngineErrorFaceTests {

    private func info(_ kind: PlaybackErrorKind, status: Int? = nil) -> PlaybackErrorInfo {
        PlaybackErrorInfo(kind: kind, message: "Failed to load: whatever", underlyingCode: status)
    }

    // MARK: A refusal, split by what the status actually says

    @Test func forbiddenAndUnauthorizedReadAsARefusal() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 403)) == .streamRefused(status: 403))
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 401)) == .streamRefused(status: 401))
    }

    @Test func goneAndNotFoundReadAsAMissingItem() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 404)) == .streamNotFound)
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 410)) == .streamNotFound)
    }

    @Test func serverSideStatusReadsAsAServerError() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 500)) == .streamServerError(status: 500))
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 502)) == .streamServerError(status: 502))
    }

    /// The copy for a refusal names its status, so a refusal without one has nothing to say that the
    /// engine's own sentence does not say better.
    @Test func aRefusalWithoutAStatusKeepsTheEngineSentence() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused)) == .engineMessage)
    }

    // MARK: The metered origin, which is a different recovery

    @Test func rateLimitedReadsAsAConnectionLimitWhicheverStatusCarriedIt() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRateLimited, status: 429)) == .rateLimited)
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRateLimited, status: 509)) == .rateLimited)
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRateLimited)) == .rateLimited)
    }

    // MARK: Device-bound failures

    @Test func dolbyVisionWithoutHardwareNamesTheDevice() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.dolbyVisionRequiresHardware)) == .dolbyVisionUnsupported)
    }

    @Test func aLiveProbeThatBurnedItsBudgetReadsAsAnUnavailableChannel() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.liveSourceUnavailable)) == .liveChannelUnavailable)
    }

    // MARK: Everything the host has no better sentence for

    /// AVFoundation already rendered its `localizedDescription` in the device's language, so replacing it
    /// with our own generic line would lose detail rather than gain a translation.
    @Test func aNativeItemFailureKeepsItsAlreadyLocalizedSentence() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.nativeItemFailed, status: -11800)) == .engineMessage)
    }

    @Test func anUnclassifiedFailureKeepsTheEngineSentence() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceOpenFailed)) == .engineMessage)
        #expect(PlayerEngineErrorPresentation.face(for: nil) == .engineMessage)
    }

    /// `PlaybackErrorKind` is a string-backed struct precisely so the engine can add kinds in a minor
    /// release. A kind this build has never heard of must fall through to the engine's sentence, not onto
    /// whichever face happens to sit last in the switch.
    @Test func aKindFromALaterEngineKeepsTheEngineSentence() {
        let future = PlaybackErrorKind(rawValue: "somethingThisBuildHasNeverHeardOf")
        #expect(PlayerEngineErrorPresentation.face(for: info(future, status: 403)) == .engineMessage)
    }

    // MARK: The live variant, where "unavailable" is the fallback rather than the verdict

    @Test func aLiveFailureWithNothingTypedStaysTheUnavailableChannel() {
        #expect(PlayerEngineErrorPresentation.liveFace(for: nil) == .liveChannelUnavailable)
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.sourceOpenFailed)) == .liveChannelUnavailable)
    }

    /// The case worth having: a one-slot panel behind Live TV is out of connections, which the viewer can
    /// act on, and which "the channel's source may be offline" would have mis-stated.
    @Test func aTypedLiveFailureBeatsTheUnavailableCopy() {
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.sourceRateLimited, status: 429)) == .rateLimited)
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.sourceRefused, status: 403)) == .streamRefused(status: 403))
    }

    // MARK: Every face has copy behind it

    @Test func everyFaceResolvesToANonEmptyTrio() {
        let faces: [PlayerEngineErrorPresentation.Face] = [
            .streamRefused(status: 403),
            .streamNotFound,
            .streamServerError(status: 503),
            .rateLimited,
            .dolbyVisionUnsupported,
            .liveChannelUnavailable,
            .engineMessage
        ]
        for face in faces {
            let trio = PlayerEngineErrorPresentation.trio(for: face, engineMessage: "raw engine sentence")
            #expect(!trio.icon.isEmpty)
            #expect(!trio.title.isEmpty)
            #expect(!trio.message.isEmpty)
        }
    }

    /// A symbol name with a typo in it renders as nothing at all rather than failing, so the error screen
    /// would simply lose its icon and no build step would say a word.
    @Test func everyIconIsARealSystemSymbol() {
        let faces: [PlayerEngineErrorPresentation.Face] = [
            .streamRefused(status: 403),
            .streamNotFound,
            .streamServerError(status: 503),
            .rateLimited,
            .dolbyVisionUnsupported,
            .liveChannelUnavailable,
            .engineMessage
        ]
        for face in faces {
            let icon = PlayerEngineErrorPresentation.trio(for: face, engineMessage: "").icon
            #expect(UIImage(systemName: icon) != nil, "\(icon) is not a system symbol on this platform")
        }
    }

    /// The raw sentence is diagnostic, not copy: it reaches the log, and the screen only when the host has
    /// nothing better.
    @Test func onlyTheFallbackFaceShowsTheEngineSentence() {
        let refused = PlayerEngineErrorPresentation.trio(for: .streamRefused(status: 403),
                                                         engineMessage: "Failed to load: HTTP 403")
        #expect(!refused.message.contains("Failed to load"))

        let fallback = PlayerEngineErrorPresentation.trio(for: .engineMessage,
                                                          engineMessage: "Failed to load: HTTP 403")
        #expect(fallback.message == "Failed to load: HTTP 403")
    }

    /// The status is the one number worth reporting back, so the two faces that carry one must render it.
    @Test func theStatusReachesTheCopyWhereTheFaceCarriesOne() {
        let refused = PlayerEngineErrorPresentation.trio(for: .streamRefused(status: 403), engineMessage: "")
        #expect(refused.message.contains("403"))

        let serverError = PlayerEngineErrorPresentation.trio(for: .streamServerError(status: 502), engineMessage: "")
        #expect(serverError.message.contains("502"))
    }
}
