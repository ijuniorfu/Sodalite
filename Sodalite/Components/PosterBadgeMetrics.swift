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

    /// Height of the resume capsule. 0.028 puts it at 6.2pt on the TV, 4.5 on iPad and 3.4 on
    /// iPhone, against the fixed 10pt it replaces, which was 4.5 percent of a TV poster and 8.3
    /// percent of a phone one and read as a bottom frame rather than as progress (Sodalite#99).
    /// The floor keeps it a visible bar rather than a hairline at the smallest tier.
    static func trackHeight(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        max(3, posterWidth * 0.028 * scale)
    }

    /// Capsule to remaining-time label. Wider than a text space at every tier, so the meter and the
    /// number read as two marks rather than as one run.
    static func labelGap(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        posterWidth * 0.036 * scale
    }

    /// The remaining-time label beside the resume capsule, deliberately smaller than `fontSize`.
    /// The quality pills carry a scrim and a hairline, so they hold their own at 0.09; a bare number
    /// at that size dominates the poster. Rendered at 0.09, 0.08, 0.075, 0.07 and 0.065 over a
    /// bright and a busy still, 0.075 is the largest that still reads as an annotation, and it is
    /// 16.5pt on the TV, 12 on iPad and 9 on iPhone.
    static func remainingLabelSize(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        posterWidth * 0.075 * scale
    }

    /// Below this share of the card the meter stops reading as a meter, so the label is dropped and
    /// the capsule keeps the full row. Only a long localized hour form on the smallest poster gets
    /// there: measured against all 26 locales, zh-Hans "3小时48分钟" is the single case.
    static let minimumTrackShare: CGFloat = 0.35
}
