import SwiftUI

/// The pills in a card's top-left corner (Sodalite#79).
///
/// A leaf on purpose: it, not `MediaCard`, reads the badge store, so a batch of enrichment landing
/// invalidates the overlays and not the two hundred cards around them. The top right belongs to the
/// watched checkmark and the bottom edge to the resume bar, so the corner is free.
struct PosterBadgeOverlay: View {
    let item: JellyfinItem
    /// The card's own width; everything here is a fraction of it, so a pill keeps its proportion
    /// on a 400pt tvOS poster and on a 160pt iPhone one.
    let cardWidth: CGFloat

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        if dependencies.appearancePreferences.showPosterBadges {
            let pills = dependencies.posterBadgeStore.badges(for: item).pills
            if !pills.isEmpty {
                VStack(alignment: .leading, spacing: cardWidth * 0.018) {
                    ForEach(pills, id: \.self, content: pill)
                }
                .padding(cardWidth * 0.03)
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: cardWidth * 0.055, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, cardWidth * 0.028)
            .padding(.vertical, cardWidth * 0.012)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}
