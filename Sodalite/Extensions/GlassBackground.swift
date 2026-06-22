import SwiftUI

extension View {
    /// Standard grey-glass page background (full-screen `.regularMaterial`) for full-screen pages (login, profile picker, filmography, changelog) so they read as glass over the dark root instead of dead black.
    func glassBackground() -> some View {
        background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
    }
}
