import Testing
@testable import Sodalite

struct ProfileRepromptPolicyTests {
    /// Baseline where every gate passes; individual tests flip one input.
    private func decide(
        elapsed: Duration = .seconds(600),
        interval: AuthPreferences.ProfileRepromptInterval = .after5min,
        launchBehavior: AuthPreferences.LaunchBehavior = .showPicker,
        isAuthenticated: Bool = true,
        rememberedCount: Int = 2,
        isPlayerActive: Bool = false,
        tvUserChanged: Bool = false
    ) -> Bool {
        ProfileRepromptPolicy.shouldReprompt(
            elapsed: elapsed, interval: interval, launchBehavior: launchBehavior,
            isAuthenticated: isAuthenticated, rememberedCount: rememberedCount,
            isPlayerActive: isPlayerActive, tvUserChanged: tvUserChanged)
    }

    @Test func baselinePrompts() { #expect(decide()) }
    @Test func offNeverPrompts() { #expect(!decide(interval: .off)) }
    @Test func immediatelyPromptsOnZeroElapsed() {
        #expect(decide(elapsed: .zero, interval: .immediately))
    }
    @Test func elapsedAtThresholdPrompts() {
        #expect(decide(elapsed: .seconds(300), interval: .after5min))
    }
    @Test func elapsedBelowThresholdDoesNot() {
        #expect(!decide(elapsed: .seconds(299), interval: .after5min))
    }
    @Test func useDefaultNeverPrompts() { #expect(!decide(launchBehavior: .useDefault)) }
    @Test func unauthenticatedNeverPrompts() { #expect(!decide(isAuthenticated: false)) }
    @Test func singleProfileNeverPrompts() { #expect(!decide(rememberedCount: 1)) }
    @Test func activePlayerBlocksPrompt() { #expect(!decide(isPlayerActive: true)) }
    @Test func tvUserChangeBlocksPrompt() { #expect(!decide(tvUserChanged: true)) }
}
