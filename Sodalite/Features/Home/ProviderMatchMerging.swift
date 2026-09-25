import Foundation

/// Two-phase provider match merge: phase 1 (Jellyfin studio query) keeps its server order on top, phase 2 (TMDB watch-provider augment) is deduped, sorted alphabetically, appended. Shared by FilteredGridView and the provider precompute (which writes the FilterCache the grid hydrates from) so a tile's cached count/order can't drift from the grid a tap opens.
enum ProviderMatchMerging {
    nonisolated static func merge(
        phase1: [JellyfinItem],
        phase2: [JellyfinItem]
    ) -> [JellyfinItem] {
        let phase1IDs = Set(phase1.map(\.id))
        let extras = phase2
            .filter { !phase1IDs.contains($0.id) }
            .sorted { $0.name < $1.name }
        return phase1 + extras
    }

    /// Cross-type key for a library item's TMDB id, matching `SeerrMedia.stableKey`'s
    /// `"movie-\(id)"` / `"tv-\(id)"` rule: TMDB reuses numeric ids across the movie and tv
    /// namespaces, so a bare `Int` key let an unrelated show's watch-provider id match a library
    /// movie, or one of two same-id items silently drop out of the phase 2 augment (Audit
    /// 2026-09-25 BROWSE-5). Shared by both tmdbMap builds (FilteredGridView, the provider
    /// precompute) so the two can't drift on which side of the movie/tv split an item lands.
    nonisolated static func tmdbKey(type: ItemType, tmdbID: Int) -> String {
        "\(type == .series ? "tv" : "movie")-\(tmdbID)"
    }
}
