import SwiftUI

/// Shared fullscreen backdrop with gradient overlay used in all detail views.
struct DetailBackdrop: View {
    let imageURL: URL?

    var body: some View {
        AsyncCachedImage(url: imageURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(Color.Theme.surface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(Color.black.opacity(0.15))
    }
}

/// Scrollable content overlay that transitions from transparent to opaque over the backdrop.
///
/// The optional `hero` slot (e.g. the title-card logo) floats over the
/// lower edge of the backdrop image, above the gradient fade, so it sits
/// on the artwork instead of the black content panel below. That keeps
/// dark logos legible (a black logo on the panel's ultraThinMaterial
/// would vanish) and frees the panel's top row to start at the title's
/// height. Defaults to empty, so overlays that pass no hero (collection,
/// catalog) render exactly as before.
struct DetailContentOverlay<Hero: View, Content: View>: View {
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let content: () -> Content

    init(
        @ViewBuilder hero: @escaping () -> Hero = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.hero = hero
        self.content = content
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Color.clear.frame(height: 500)
                    hero()
                        .padding(.horizontal, 50)
                        .padding(.bottom, 4)
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)

                VStack(alignment: .leading, spacing: 40) {
                    content()
                }
                .padding(.bottom, 80)
                .background(.black)

                // Trailing solid-black filler so a short content block
                // (e.g. once "Anfrage gesendet" has replaced the
                // request flow's tabs) doesn't leave the backdrop
                // bleeding through with a hard gradient edge at the
                // bottom of the screen. Sized large enough to push
                // past any tvOS safe-area inset on a 4K display.
                Color.black.frame(minHeight: 600)
            }
        }
    }
}
