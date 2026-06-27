import SwiftUI

/// Focusable-row activation gated on focus stability. Siri Remote finger drift in the last frames of a click can shift focus to a neighbour and activate the wrong tile; this drops presses until focus has been steady for `stableFocusWindow`. 80 ms is below human reaction to a focus shift (~200 ms) so it filters drift without latency on deliberate clicks. Caller still owns `.focusable`/`.focused` and styling.
struct StableTapModifier: ViewModifier {
    let isFocused: Bool
    let action: () -> Void

    /// Minimum steady-focus time (s) before a press fires; drop to 0.06 if 80 ms feels sluggish.
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
            // iOS touch: fire immediately. The focus-stability gate guards Siri Remote finger
            // drift and is meaningless on touch (and would never fire: isFocused stays false
            // without a focus engine, so focusAcquiredAt is always nil).
            .onTapGesture { action() }
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
    /// Stable-focus-gated tap; pass the row's `@FocusState`. See `StableTapModifier` for rationale.
    func stableTap(isFocused: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(StableTapModifier(isFocused: isFocused, action: action))
    }
}
