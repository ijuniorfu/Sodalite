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
struct DetailContentOverlay<Content: View>: View {
    /// Bump this from a parent to scroll the overlay back to the very top
    /// (full backdrop visible). Detail views use it to open consistently
    /// on the hero regardless of tvOS's focus-driven scroll. Defaults to 0
    /// for callers that don't need it.
    var scrollToTopToken: Int = 0
    @ViewBuilder let content: () -> Content

    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 500)

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
        .scrollPosition($scrollPosition)
        .onChange(of: scrollToTopToken) { _, _ in
            scrollPosition.scrollTo(edge: .top)
        }
    }
}
