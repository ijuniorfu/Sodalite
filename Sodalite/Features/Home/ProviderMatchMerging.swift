import Foundation

/// Shared merge for the two-phase streaming-provider match: phase 1
/// (Jellyfin studio-name query) keeps its server-side ordering at the
/// top, phase 2 (TMDB watch-provider augment) is deduped against it,
/// sorted alphabetically, and appended.
///
/// Both FilteredGridView's grid refresh and HomeViewModel's provider
/// precompute build their lists through this one helper. They feed
/// the same FilterCache entries (the precompute writes what the grid
/// hydrates from), so the two call sites drifting apart would make a
/// tile's cached count/order disagree with the grid a tap opens.
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
