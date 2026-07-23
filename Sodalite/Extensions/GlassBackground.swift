import SwiftUI

struct GraphiteGlassBackground: View {
    var body: some View {
        #if os(iOS)
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

extension View {
    func glassBackground() -> some View {
        background { GraphiteGlassBackground() }
    }

    func themedStaticBackground() -> some View {
        modifier(ThemedStaticBackgroundModifier())
    }
}

private struct ThemedStaticBackgroundModifier: ViewModifier {
    @Environment(\.appearanceTheme) private var theme

    func body(content: Content) -> some View {
        content.background {
            AppBackgroundView(theme: theme, mode: .static)
        }
    }
}
