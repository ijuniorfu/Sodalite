import SwiftUI

/// Title-card logo for the detail screens. Renders the logo image left-aligned at a capped height when the item has a Logo and logos are enabled; otherwise the caller's text-title fallback (so each surface keeps its own styling).
struct ContentLogoTitle<Fallback: View>: View {

    /// Item that owns the logo; for episodes this is the SERIES item (no per-episode logo exists).
    let itemID: String
    /// Capped logo height, sized per surface by the caller.
    let maxHeight: CGFloat
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.dependencies) private var dependencies

    /// Logo URL by item ID only: `/Items/{id}/Images/Logo` serves the current logo tagless, so it loads on the first frame from a series stub (episode deep-link) with no imageTags round-trip, and stays stable when the stub is replaced (no reload/flash). No-logo items 404 to the text fallback. nil only when logos are off.
    private var logoURL: URL? {
        guard dependencies.appearancePreferences.showContentLogos else {
            return nil
        }
        return dependencies.jellyfinImageService.imageURL(
            itemID: itemID,
            imageType: .logo,
            maxWidth: 600
        )
    }

    var body: some View {
        // Always an AsyncCachedImage, never a branch: the fallback is its placeholder, so the stable per-id URL never swaps the subtree or resets `.id` to disturb the enclosing ScrollView.
        AsyncCachedImage(url: logoURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: maxHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } placeholder: {
            fallback()
        }
        // Light glow lifts a dark logo off a dark backdrop; dark drop shadow gives a light logo separation on a bright one. Together they keep the hero legible on any artwork.
        .shadow(color: .white.opacity(0.45), radius: 6)
        .shadow(color: .black.opacity(0.55), radius: 14, y: 4)
    }
}

/// Backdrop hero logo. Addressed by viewModel.item.id (the series id even for an episode-stub), so the logo loads on the first frame; reading viewModel.item keeps the text fallback in sync once the real name lands.
struct DetailHeroLogo: View {
    let viewModel: DetailViewModel
    var maxHeight: CGFloat = 150

    var body: some View {
        ContentLogoTitle(
            itemID: viewModel.item.id,
            maxHeight: maxHeight
        ) {
            Text(viewModel.item.name)
                .font(.largeTitle)
                .fontWeight(.bold)
        }
    }
}
