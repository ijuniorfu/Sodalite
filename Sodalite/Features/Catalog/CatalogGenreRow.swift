import SwiftUI

/// Horizontal scroller of genre tiles (dimmed backdrop + name overlay, matching Jellyseerr web's discover sliders); tap navigates to a CatalogFilteredGridView.
struct CatalogGenreRow: View {
    let titleKey: LocalizedStringKey
    let genres: [SeerrGenreSlide]
    let kind: Kind
    let onSelect: (CatalogFilter) -> Void

    enum Kind { case movie, tv }

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
                    ForEach(genres) { genre in
                        GenreTile(genre: genre) {
                            onSelect(filter(for: genre))
                        }
                    }
                }
                .padding(.horizontal, metrics.rowInset)
                // Match SeerrHorizontalMediaRow vertical padding so the focus halo doesn't clip adjacent rows.
                .padding(.vertical, metrics.rowVerticalPadding)
            }
            .focusSectionCompat()
        }
    }

    private func filter(for genre: SeerrGenreSlide) -> CatalogFilter {
        switch kind {
        case .movie: .movieGenre(id: genre.id, name: genre.name)
        case .tv: .tvGenre(id: genre.id, name: genre.name)
        }
    }
}

private struct GenreTile: View {
    let genre: SeerrGenreSlide
    let action: () -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var width: CGFloat { LayoutMetrics.current(hSizeClass).genreTileSize.width }
    private var height: CGFloat { LayoutMetrics.current(hSizeClass).genreTileSize.height }

    var body: some View {
        // FocusableCard not Button: tvOS layers an unsuppressable white halo on focused .plain buttons, so all cards route through this primitive (own scale, shadow, and semantic focus outline).
        FocusableCard(action: action) { isFocused in
            ZStack {
                if let path = genre.primaryBackdrop,
                   let url = SeerrImageURL.backdrop(path: path, size: .w780) {
                    AsyncCachedImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        fallbackBackground
                    }
                    .frame(width: width, height: height)
                    .clipped()
                } else {
                    fallbackBackground
                }

                LinearGradient(
                    colors: [.black.opacity(0.2), .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Text(genre.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
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

    private var fallbackBackground: some View {
        // LinearGradient(colors:) needs concrete Colors, so resolve the effective control-role palette here.
        let tint = dependencies.appearancePreferences.resolvedTheme(
            isSupporter: dependencies.storeKitService.isSupporter
        ).palette.control.color
        return LinearGradient(
            colors: [tint.opacity(0.5), tint.opacity(0.2)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(width: width, height: height)
    }
}
