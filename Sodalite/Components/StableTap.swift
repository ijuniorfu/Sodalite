import SwiftUI

/// View modifier that wraps the standard Sodalite focusable-row activation
/// (clickpad press fires the action) with a focus-stability check.
///
/// On the Siri Remote, tiny finger drift in the last frames of a click can
/// shift focus from the user's intended target onto a neighbouring row,
/// so the click activates the wrong tile. This modifier records when the
/// row most recently acquired focus and only fires the action if focus
/// has been stable for at least `stableFocusWindow`. Below that threshold
/// the press is silently dropped (the user will press again on the row
/// they actually want).
///
/// 80 ms is below typical human reaction time to a visual focus shift
/// (~200 ms) so it filters drift inside a single click motion without
/// adding perceptible latency to deliberate fast clicks.
///
/// Replaces the `.onLongPressGesture(minimumDuration: 0.01) { action() }`
/// / `.onTapGesture { action() }` pair on focusable rows. The caller
/// still owns `.focusable(true)` and `.focused($focused)`, and continues
/// to drive any tint-stroke or scale-effect styling off the same
/// `@FocusState`.
struct StableTapModifier: ViewModifier {
    let isFocused: Bool
    let action: () -> Void

    /// Minimum time (s) that focus must have been steady on this row
    /// before a press is allowed to fire the action. Drop to 0.06 if
    /// 80 ms ever feels sluggish in practice.
    static let stableFocusWindow: TimeInterval = 0.08

    @State private var focusAcquiredAt: Date?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isFocused { focusAcquiredAt = Date() }
            }
            .onChange(of: isFocused) { _, newValue in
                focusAcquiredAt = newValue ? Date() : nil
            }
            #if os(tvOS)
            .onLongPressGesture(minimumDuration: 0.01) { fireIfStable() }
            #else
            .onTapGesture { fireIfStable() }
            #endif
    }

    private func fireIfStable() {
        guard let acquired = focusAcquiredAt else { return }
        if Date().timeIntervalSince(acquired) >= Self.stableFocusWindow {
            action()
        }
    }
}

extension View {
    /// Apply a stable-focus-gated tap activation to a focusable row.
    ///
    /// Pass the same `@FocusState` value the row uses for its focus
    /// styling. The action fires only after focus has been steady on
    /// this row for `StableTapModifier.stableFocusWindow`. See the
    /// modifier docs for the rationale.
    func stableTap(isFocused: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(StableTapModifier(isFocused: isFocused, action: action))
    }
}
