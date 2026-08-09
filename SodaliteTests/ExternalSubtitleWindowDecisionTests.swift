import Foundation
import Testing

@testable import Sodalite

@Suite("External subtitle window decision (Sodalite#98)")
struct ExternalSubtitleWindowDecisionTests {
    private func decide(
        attached: Bool = true, subtitle: Bool = true, failed: Bool = false
    ) -> Bool {
        ExternalSubtitleWindowDecision.shouldOwnExternalScreen(
            externalDisplayAttached: attached, subtitleSelected: subtitle, handoverFailed: failed)
    }

    @Test("takes the screen for a selected subtitle on an attached display")
    func takesTheScreen() {
        #expect(decide())
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
