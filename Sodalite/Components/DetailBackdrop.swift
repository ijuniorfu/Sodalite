import SwiftUI

/// Shared fullscreen backdrop with gradient overlay used in all detail views.
struct DetailBackdrop: View {
    let imageURL: URL?
    /// Blur-fill stand-in for items without any backdrop art: the
    /// portrait poster (or primary image), zoomed past the frame and
    /// heavily blurred so it reads as ambient color rather than a
    /// stretched poster. Replaces the flat grey plate (Sodalite#15).
    var posterFallbackURL: URL? = nil

    private var usesPosterFill: Bool {
        imageURL == nil && posterFallbackURL != nil
    }

    var body: some View {
        AsyncCachedImage(url: imageURL ?? posterFallbackURL) { image in
            if usesPosterFill {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.3)
                    .blur(radius: 64)
            } else {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        } placeholder: {
            Rectangle().fill(Color.Theme.surface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // The blur fill is busier than real backdrop art, give it a
        // slightly stronger dim so the hero text stays readable.
        .overlay(Color.black.opacity(usesPosterFill ? 0.3 : 0.15))
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
                Color.clear.frame(height: 500)

                // The hero (logo / title) rides as an overlay on the
                // gradient rather than a separate stacked layer, so the
                // scroll content stays the same three siblings (clear,
                // gradient, content) the focus engine scrolls through.
                // Bottom-aligned, it sits just above the content panel at
                // the gradient's lower edge, and being an overlay it draws
                // on top of the gradient so the logo stays visible.
                // Full-bleed redesign (Sodalite#15): the lower half no
                // longer fades to near-black; the backdrop stays
                // visible behind a scrim and the text containers carry
                // their own material backgrounds for legibility.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
                .overlay(alignment: .bottomLeading) {
                    hero()
                        .padding(.horizontal, 50)
                        .padding(.bottom, 8)
                }

                VStack(alignment: .leading, spacing: 40) {
                    content()
                }
                .padding(.bottom, 80)
                .background(Color.black.opacity(0.55))

                // Trailing filler so a short content block (e.g. once
                // "Anfrage gesendet" has replaced the request flow's
                // tabs) doesn't end in a hard gradient edge at the
                // bottom of the screen. Same scrim as the content
                // block so the backdrop keeps shining through. Sized
                // large enough to push past any tvOS safe-area inset
                // on a 4K display.
                Color.black.opacity(0.55).frame(minHeight: 600)
            }
        }
    }
}
