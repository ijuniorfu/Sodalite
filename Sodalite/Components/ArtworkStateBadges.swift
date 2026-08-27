import SwiftUI

/// The viewer's own state drawn on top of artwork: the watched check, and the favourite heart
/// beside it on the episode strip.
///
/// `checkmark.circle.fill` cuts its check OUT of the disc, so under a single fill the check is not
/// drawn at all, it is the poster showing through a hole. On bright art that reads white by luck,
/// on busy or dark art the shape breaks up or disappears (Sodalite#89). Palette rendering paints
/// the glyph white and the disc in the tint, which is what every comparable client does, and a soft
/// shadow gives the disc an edge on bright stills. It was the only overlay on the artwork with no
/// contrast treatment at all: the pills opposite sit on a scrim with a hairline, and the resume bar
/// keeps an opaque track for the same reason.
///
/// Sized off the tier's poster width like those pills, not off the card it sits on, so a landscape
/// card wears the same badge as the poster beside it, it tracks the card-scale setting, and it stops
/// growing with the viewer's Dynamic Type setting on iOS.
struct ArtworkStateBadges: View {
    var isFavorite: Bool = false
    var isPlayed: Bool
    /// The tier's poster width, not this card's width.
    let posterWidth: CGFloat
    var scale: CGFloat = 1

    private var diameter: CGFloat { PosterBadgeMetrics.checkDiameter(posterWidth: posterWidth, scale: scale) }
    private var inset: CGFloat { PosterBadgeMetrics.checkInset(posterWidth: posterWidth, scale: scale) }

    var body: some View {
        if isFavorite || isPlayed {
            // One stack for both: pinned separately they would land on the same point.
            HStack(spacing: diameter * 0.22) {
                if isFavorite {
                    badge("heart.fill")
                }
                if isPlayed {
                    // Two styles, so the symbol renders as a palette: white check, tinted disc.
                    badge("checkmark.circle.fill", glyph: .white)
                }
            }
            .padding(inset)
        }
    }

    @ViewBuilder
    private func badge(_ symbol: String, glyph: Color? = nil) -> some View {
        let image = Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: diameter, height: diameter)

        Group {
            if let glyph {
                image.foregroundStyle(glyph, .tint)
            } else {
                image.foregroundStyle(.tint)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: diameter * 0.12, y: diameter * 0.05)
    }
}
