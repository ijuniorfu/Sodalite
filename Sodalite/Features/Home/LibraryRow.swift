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
    private var size: CGSize { LayoutMetrics.current(hSizeClass).landscapeSize }

    var body: some View {
        ArtworkTile(
            title: library.name,
            artworkURL: dependencies.jellyfinImageService.libraryArtworkURL(for: library),
            size: size,
            action: action
        ) {
            ZStack {
                ArtworkTileSurface()

                // No Primary/Thumb on the server: the generic tile. The icon sits in the corner
                // rather than above the name, which on a compact tile would overlap it.
                Image(systemName: symbol(for: library.libraryType))
                    .font(.system(size: size.height * 0.22))
                    .foregroundStyle(.tint)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
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
