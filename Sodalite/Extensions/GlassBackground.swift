import SwiftUI

extension View {
    /// Standard grey-glass page background (full-screen `.regularMaterial`) for full-screen pages (login, profile picker, filmography, changelog) so they read as glass over the dark root instead of dead black.
    func glassBackground() -> some View {
        background {
            #if os(iOS)
            // iOS dark-mode `.regularMaterial` over the black root renders almost black (unlike tvOS,
            // where the same material is a bright frosted panel). Lift it with a faint top-down white
            // wash so full-screen pages read as frosted glass instead of dead black.
            Rectangle()
                .fill(.regularMaterial)
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.12), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            #else
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            #endif
        }
    }
}
