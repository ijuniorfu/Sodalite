import SwiftUI

extension View {
    /// Hides the tab bar while this full-screen detail is on screen (pushed details that are NOT presented as a cover still need this). Details presented via a full-screen cover do not need it: the cover covers the bar without ever removing it, so the bar is never re-templated gray on dismiss.
    func hidesShellTabBar() -> some View {
        // tvOS-only: hiding the tab bar stops tvOS re-templating its icons gray on a pushed
        // detail. On iOS the hide is what strands the bar after a pop, so keep the native
        // tab bar (it hides/restores correctly on push/pop by itself).
        #if os(tvOS)
        return toolbar(.hidden, for: .tabBar)
        #else
        return self
        #endif
    }
}
