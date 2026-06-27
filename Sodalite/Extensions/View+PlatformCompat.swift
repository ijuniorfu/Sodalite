import SwiftUI

// No-op-on-iOS shims for tvOS-only focus/command modifiers so shared views
// compile Universal. On tvOS the real modifier applies; on iOS the equivalent
// affordance comes from native touch navigation (back swipe / Now Playing remote)
// or is wired up in a later port phase. Keep call sites identical across platforms.
//
// onMoveCommand is also tvOS-only but carries real navigation behavior with no
// iOS analog yet, so it is gated inline with #if os(tvOS) at each site (replaced
// by touch controls in Phase 2) rather than silently no-op'd here.
extension View {
    @ViewBuilder
    func focusSectionCompat() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder
    func focusScopeCompat(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        focusScope(namespace)
        #else
        self
        #endif
    }

    @ViewBuilder
    func prefersDefaultFocusCompat(_ prefersDefaultFocus: Bool, in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        self.prefersDefaultFocus(prefersDefaultFocus, in: namespace)
        #else
        self
        #endif
    }

    /// tvOS hides the navigation bar (it uses the Menu button to go back); iOS keeps the
    /// native bar so pushed screens get a back button and the interactive swipe-back gesture.
    @ViewBuilder
    func hidesNavigationBarChrome() -> some View {
        #if os(tvOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func onExitCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }

    @ViewBuilder
    func onPlayPauseCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onPlayPauseCommand(perform: action)
        #else
        self
        #endif
    }
}
