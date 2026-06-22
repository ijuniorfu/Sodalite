import SwiftUI

/// Horizontal scroller of network/studio tiles (TMDB logo on a dark card); tap pushes a CatalogFilteredGridView. Mirrors Jellyseerr web's CompanyCard slider.
struct CatalogProviderRow: View {
    let titleKey: LocalizedStringKey
    let providers: [CatalogProvider]
    /// Destination chosen by caller: Catalog wraps in a `CatalogFilter`, Home translates to a Jellyfin Studios filter.
    let onSelect: (CatalogProvider) -> Void
    /// Per-provider sample backdrop resolver (local Jellyfin for home, Jellyseerr discover for catalog); nil falls back to the dark logo-only tile.
    var backdropFor: (CatalogProvider) -> URL? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 50)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(providers) { provider in
                        ProviderTile(
                            provider: provider,
                            backdropURL: backdropFor(provider)
                        ) {
                            onSelect(provider)
                        }
                    }
                }
                .padding(.horizontal, 50)
                .padding(.vertical, 16)
            }
        }
    }
}

private struct ProviderTile: View {
    let provider: CatalogProvider
    let backdropURL: URL?
    let action: () -> Void

    // Match genre tile dimensions so provider + genre rows line up on the same screen.
    private let width: CGFloat = 320
    private let height: CGFloat = 180

    var body: some View {
        // FocusableCard not Button: tvOS layers an unsuppressable white halo on focused buttons (as GenreTile/SeerrMediaCard).
        FocusableCard(action: action) { isFocused in
            ZStack {
                if let backdropURL {
                    AsyncCachedImage(url: backdropURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color(white: 0.08)
                    }
                    .frame(width: width, height: height)
                    .clipped()

                    // Heavier than the genre tile gradient so the duotone logo stays readable on bright backdrops.
                    LinearGradient(
                        colors: [.black.opacity(0.55), .black.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Color(white: 0.08)
                }

                if let url = SeerrImageURL.duotoneLogo(path: provider.logoPath) {
                    AsyncCachedImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(28)
                    } placeholder: {
                        nameLabel
                    }
                } else {
                    nameLabel
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, lineWidth: 4)
                    .opacity(isFocused ? 1 : 0)
            )
        }
    }

    private var nameLabel: some View {
        Text(provider.name)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }
}
