import SwiftUI

/// "My Media" row: one tile per video library, opening it in the shared FilteredGridView.
struct LibraryRow: View {
    let titleKey: LocalizedStringKey
    let libraries: [JellyfinLibrary]
    let onSelect: (JellyfinLibrary) -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(libraries) { library in
                        LibraryTile(library: library) {
                            onSelect(library)
                        }
                    }
                }
                .padding(.horizontal, metrics.rowInset)
                .padding(.vertical, metrics.rowVerticalPadding)
            }
            .focusSectionCompat()
        }
    }
}

private struct LibraryTile: View {
    let library: JellyfinLibrary
    let action: () -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    // Match .landscape MediaCard dimensions so My Media tiles line up with the rows above.
    private var width: CGFloat { LayoutMetrics.current(hSizeClass).landscapeSize.width }
    private var height: CGFloat { LayoutMetrics.current(hSizeClass).landscapeSize.height }

    var body: some View {
        // Scrim, font and bottom-leading label are GenreCard's, deliberately: My Media and Genres
        // sit on the same screen and the two rows have to read as one design (Sodalite#84).
        FocusableCard(action: action) { isFocused in
            ZStack(alignment: .bottomLeading) {
                if let artworkURL = dependencies.jellyfinImageService.libraryArtworkURL(for: library) {
                    AsyncCachedImage(url: artworkURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholderBackground
                    }
                    .frame(width: width, height: height)
                    .clipped()

                    Rectangle()
                        .fill(.black.opacity(0.55))
                } else {
                    // No Primary/Thumb on the server: the generic tile, with the icon out of the
                    // label's way rather than above it.
                    placeholderBackground

                    Image(systemName: symbol(for: library.libraryType))
                        .font(.system(size: height * 0.22))
                        .foregroundStyle(.tint)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                Text(library.name)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .lineLimit(2)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                MediaFocusRing(
                    shape: RoundedRectangle(cornerRadius: 16),
                    isFocused: isFocused
                )
            )
        }
    }

    private var placeholderBackground: some View {
        LinearGradient(
            colors: [Color(white: 0.16), Color(white: 0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: width, height: height)
    }

    private func symbol(for type: LibraryType) -> String {
        switch type {
        case .movies: "film"
        case .tvshows: "tv"
        case .homevideos: "video"
        default: "rectangle.stack"
        }
    }
}
