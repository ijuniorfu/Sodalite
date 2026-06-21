import SwiftUI

extension View {
    /// The app's standard grey-glass page background: a frosted
    /// `.regularMaterial` filling the whole screen. Replaces flat `Color.black`
    /// / the opaque system `.background` on full-screen pages (login, profile
    /// picker, filmography, changelog, …) so they share one consistent look
    /// instead of dead black. Material frosts whatever sits behind the page
    /// (the app's dark root, or the view it was pushed over), so it reads as
    /// grey glass rather than a flat fill.
    func glassBackground() -> some View {
        background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
    }
}
