import SwiftUI

/// The one 16:9 "artwork with a name on it" tile: Home's Genres and My Media rows, Catalog's genre
/// rows. Sodalite#84 was these drifting apart (one centered its label, its neighbour put it bottom
/// left), so scrim, label and shape live here once instead of three times.
///
/// `fallback` paints both the loading state and the no-artwork state, so a caller can hand over a
/// plain gradient or a gradient with a generic icon on it. The scrim goes over it either way, which
/// is what keeps the label reading the same in both.
struct ArtworkTile<Fallback: View>: View {
    let title: String
    let artworkURL: URL?
    let size: CGSize
    let action: () -> Void
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        // FocusableCard not Button: tvOS layers an unsuppressable white halo on focused buttons.
        FocusableCard(action: action) { isFocused in
            ZStack(alignment: .bottomLeading) {
                if let artworkURL {
                    AsyncCachedImage(url: artworkURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        fallback()
                    }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                } else {
                    fallback()
                }

                // A gradient, not a flat veil: the label sits at the bottom, so that is the only
                // band that needs contrast, and dimming the whole frame greyed out the artwork
                // these rows exist to show. The bottom stop is darker than the old flat scrim, so
                // legibility under the label goes up, not down.
                LinearGradient(
                    colors: [.black.opacity(0.15), .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Text(title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .lineLimit(2)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                MediaFocusRing(
                    shape: RoundedRectangle(cornerRadius: 16),
                    isFocused: isFocused
                )
            )
        }
    }
}

/// The neutral tile ground, shared by every caller that has no themed fallback of its own.
struct ArtworkTileSurface: View {
    var body: some View {
        LinearGradient(
            colors: [Color.Theme.surface, Color.Theme.surfaceElevated],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
