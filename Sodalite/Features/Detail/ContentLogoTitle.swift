import SwiftUI

/// Title-card logo for the detail screens. When the item carries a Logo
/// image and the user has logos enabled (Appearance settings, default
/// on), renders the logo image left-aligned at a capped height. Falls
/// back to the supplied text-title view otherwise: no logo tag, logos
/// turned off, or while the image is still loading.
///
/// The fallback is passed in by the call site so each surface keeps its
/// own type styling (large bold title on Movie / Series root, the series
/// name behind the episode logo in the episode panel).
struct ContentLogoTitle<Fallback: View>: View {

    /// Item that owns the logo. For episodes this is the SERIES item, so
    /// the episode panel shows the show's logo, not a (nonexistent)
    /// per-episode one.
    let itemID: String
    /// Capped logo height. Sized per surface by the caller.
    let maxHeight: CGFloat
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.dependencies) private var dependencies

    /// Resolved logo URL, addressed by item ID only. Jellyfin's
    /// `/Items/{id}/Images/Logo` serves the current logo without an image
    /// tag (the tag is just a cache key), so this works even when we only
    /// hold a stub: an episode deep-link opens SeriesDetailView with a
    /// series stub whose id IS the series id, so the show's logo loads on
    /// the first frame, no imageTags round-trip required. The id-based URL
    /// is also stable across the stub being replaced by the full item, so
    /// the image never reloads or flashes. Items without a logo simply 404
    /// and fall back to the text title. Returns nil only when logos are
    /// turned off.
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
        // Always an AsyncCachedImage, never a branch between image and
        // text. The fallback text shows as the placeholder while the logo
        // loads, and stays put for items that have no logo (the request
        // 404s). The URL is stable per item id, so there is no subtree
        // swap or `.id` reset to disturb the enclosing ScrollView.
        AsyncCachedImage(url: logoURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: maxHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } placeholder: {
            fallback()
        }
        // Light glow first: lifts a dark logo (e.g. Modern Family's
        // black wordmark) off a dark backdrop, where a drop shadow alone
        // does nothing. Dark drop shadow second: gives a light logo
        // separation on a bright backdrop. Together they keep the hero
        // legible on any artwork.
        .shadow(color: .white.opacity(0.45), radius: 6)
        .shadow(color: .black.opacity(0.55), radius: 14, y: 4)
    }
}

/// Backdrop hero logo for the Movie / Series detail screens. The logo is
/// addressed by `viewModel.item.id`, which is the series id even for an
/// episode deep-link's stub, so the show's logo loads on the first frame
/// without waiting for the full detail. Reading `viewModel.item` keeps the
/// text fallback (the item name) in sync once the real name lands.
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
