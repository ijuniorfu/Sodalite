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
    let logoTag: String?
    /// Capped logo height. Sized per surface by the caller.
    let maxHeight: CGFloat
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.dependencies) private var dependencies

    /// Resolved logo URL, or nil when logos are off or the item has no
    /// logo tag yet. Computed (not branched in the body) so the view
    /// structure below stays stable across the tag arriving.
    private var logoURL: URL? {
        guard dependencies.appearancePreferences.showContentLogos,
              let tag = logoTag else {
            return nil
        }
        return dependencies.jellyfinImageService.imageURL(
            itemID: itemID,
            imageType: .logo,
            tag: tag,
            maxWidth: 600
        )
    }

    var body: some View {
        // Always an AsyncCachedImage, never a branch between image and
        // text. With no logo (or logos off) the URL is nil and the
        // fallback text shows as the placeholder. When the logo tag
        // arrives late (an episode deep-link opens SeriesDetailView with
        // a series stub that has no imageTags yet), the URL flips
        // nil -> value and AsyncCachedImage's own `.task(id: url)` loads
        // it in place. No subtree swap and no `.id` reset, either of
        // which would disturb the enclosing ScrollView's scroll position
        // and focus-driven scrolling.
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
