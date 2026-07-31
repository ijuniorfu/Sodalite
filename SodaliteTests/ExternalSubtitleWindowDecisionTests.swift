import Foundation
import Testing

@testable import Sodalite

@Suite("External subtitle window decision (Sodalite#98)")
struct ExternalSubtitleWindowDecisionTests {
    private func decide(
        attached: Bool = true, subtitle: Bool = true,
        nativeServed: Bool = false, failed: Bool = false
    ) -> Bool {
        ExternalSubtitleWindowDecision.shouldOwnExternalScreen(
            externalDisplayAttached: attached, subtitleSelected: subtitle,
            nativeRenditionsServed: nativeServed, handoverFailed: failed)
    }

    @Test("takes the screen for a selected subtitle the renditions cannot reach")
    func takesTheScreen() {
        #expect(decide())
    }

    @Test("leaves the screen to AVKit when native renditions already carry the subtitles")
    func nativeRenditionsWin() {
        #expect(!decide(nativeServed: true))
    }

    @Test("never takes a screen that is not attached, or with no subtitle selected")
    func requiresBothInputs() {
        #expect(!decide(attached: false))
        #expect(!decide(subtitle: false))
    }

    @Test("stays off for the session once a takeover produced no picture")
    func failedHandoverLatches() {
        #expect(!decide(failed: true))
    }
}
