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
}
