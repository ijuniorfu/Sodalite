import SwiftUI

extension View {
    /// Fills in the badge pills for a row or grid of items once it is on screen (Sodalite#79).
    /// Attach it to the container, never to a card: the point is that one request covers the whole
    /// row rather than one per card.
    func enrichesPosterBadges(_ items: [JellyfinItem]) -> some View {
        modifier(PosterBadgeEnrichment(items: items))
    }
}

private struct PosterBadgeEnrichment: ViewModifier {
    let items: [JellyfinItem]

    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    func body(content: Content) -> some View {
        content
            // The setting is part of the id so switching it on fills the corners in without a
            // reload; the ids so a row that swapped its content enriches the new one.
            .task(id: EnrichmentKey(itemIDs: items.map(\.id),
                                    enabled: dependencies.appearancePreferences.showPosterBadges)) {
                guard let userID = appState.activeUser?.id else { return }
                await dependencies.posterBadgeStore.enrich(userID: userID, items)
            }
    }

    private struct EnrichmentKey: Equatable {
        let itemIDs: [String]
        let enabled: Bool
    }
}
