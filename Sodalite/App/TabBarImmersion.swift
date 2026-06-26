import SwiftUI

extension View {
    /// Hides the tab bar while this full-screen detail is on screen (pushed details that are NOT presented as a cover still need this). Details presented via a full-screen cover do not need it: the cover covers the bar without ever removing it, so the bar is never re-templated gray on dismiss.
    func hidesShellTabBar() -> some View {
        toolbar(.hidden, for: .tabBar)
    }
}
