import Foundation

/// Pure launch decision for the who's-watching reprompt after background time (issue #41).
/// Convenience only, not a security lock: the Guardian PIN keeps gating profile activation.
enum ProfileRepromptPolicy {
    static func shouldReprompt(
        elapsed: Duration,
        interval: AuthPreferences.ProfileRepromptInterval,
        launchBehavior: AuthPreferences.LaunchBehavior,
        isAuthenticated: Bool,
        rememberedCount: Int,
        isPlayerActive: Bool,
        tvUserChanged: Bool
    ) -> Bool {
        guard let threshold = interval.threshold else { return false }
        guard launchBehavior == .showPicker else { return false }
        guard isAuthenticated, rememberedCount > 1 else { return false }
        guard !isPlayerActive, !tvUserChanged else { return false }
        return elapsed >= threshold
    }
}
