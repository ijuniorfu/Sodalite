import SwiftUI

/// The pills in a card's top-left corner (Sodalite#79).
///
/// A leaf on purpose: it, not `MediaCard`, reads the badge store, so a batch of enrichment landing
/// invalidates the overlays and not the two hundred cards around them. The top right belongs to the
/// watched checkmark and the bottom edge to the resume bar, so the corner is free.
struct PosterBadgeOverlay: View {
    let item: JellyfinItem
    let fontSize: CGFloat

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        if dependencies.appearancePreferences.showPosterBadges {
            let pills = dependencies.posterBadgeStore.badges(for: item).pills
            if !pills.isEmpty {
                VStack(alignment: .leading, spacing: fontSize * 0.2) {
                    ForEach(pills, id: \.self, content: pill)
                }
                .padding(fontSize * 0.35)
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, fontSize * 0.42)
            .padding(.vertical, fontSize * 0.18)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}
