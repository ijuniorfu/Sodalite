import SwiftUI

/// Pill geometry, sized off the tier's poster width rather than the card the pill sits on.
///
/// Measured with NSFont at the tvOS text sizes rather than guessed at the TV: 0.09 of the poster
/// width is 19.8pt on Apple TV, just under the 25pt title beneath the card, 14.4pt on iPad and
/// 10.8pt on iPhone, which is caption2 there. Sizing a pill off its own card would put a 32pt pill
/// on a landscape card next to a 20pt one on the poster beside it.
enum PosterBadgeMetrics {
    static func fontSize(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        posterWidth * 0.09 * scale
    }

    /// Diameter of the watched check opposite the pills (Sodalite#89). Every comparable client
    /// draws that disc at 12 to 16 percent of the poster, and 0.13 puts it at 28.6pt on the TV,
    /// 20.8 on iPad and 15.6 on iPhone. It replaces a fixed `.title3`, which measured near 17
    /// percent on both tiers, grew with Dynamic Type on iOS, and ignored the card-scale setting
    /// while the card around it shrank.
    static func checkDiameter(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        posterWidth * 0.13 * scale
    }

    /// Inset from the artwork corner. The fixed 10pt it replaces was 4.5 percent of a TV poster and
    /// 8.3 percent of a phone one, so the badge crowded the corner on the smallest tier.
    static func checkInset(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        posterWidth * 0.045 * scale
    }
}
