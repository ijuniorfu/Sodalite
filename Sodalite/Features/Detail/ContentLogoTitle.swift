import SwiftUI

/// Title-card logo for the detail screens. When the item carries a Logo
/// image and the user has logos enabled (Appearance settings, default
/// on), renders the logo image left-aligned at a capped height. Falls
/// back to the supplied text-title view otherwise: no logo tag, logos
/// turned off, or while the image is still loading.
///
/// The fallback is passed in by the call site so each surface keeps its
/// own type styling (large bold title on Movie / Series root, smaller
/// eyebrow above the episode title in the episode panel).
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

    private var showLogos: Bool { dependencies.appearancePreferences.showContentLogos }

    var body: some View {
        if showLogos,
           let tag = logoTag,
           let url = dependencies.jellyfinImageService.imageURL(
               itemID: itemID,
               imageType: .logo,
               tag: tag,
               maxWidth: 600
           ) {
            AsyncCachedImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                fallback()
            }
            .frame(maxHeight: maxHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            fallback()
        }
    }
}
