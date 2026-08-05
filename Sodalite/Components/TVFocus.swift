import SwiftUI

/// tvOS focus-scope plumbing, no-ops elsewhere. iPad renders the same screens but has no focus
/// engine to direct, and both modifiers are unavailable there.
extension View {
    @ViewBuilder
    func tvFocusScope(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        focusScope(namespace)
        #else
        self
        #endif
    }

    @ViewBuilder
    func tvPrefersDefaultFocus(in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        prefersDefaultFocus(true, in: namespace)
        #else
        self
        #endif
    }
}
