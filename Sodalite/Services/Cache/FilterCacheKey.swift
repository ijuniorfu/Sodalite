import Foundation

/// Single source of truth for `FilterCache` keys: writers and readers share these factories so a key-format change can't make a reader miss a writer's blob (silent "loading flash on every tap"). Two namespaces (Home → JellyfinItem slice, Catalog → SeerrMedia slice). `nonisolated` throughout so precompute fan-out tasks avoid a MainActor hop.
enum FilterCacheKey {
    enum Home {
        /// Streaming-provider tile. Region is in the key: TMDB watch-providers are region-specific (Disney+ DE ≠ US lineup).
        nonisolated static func provider(id: Int, region: String) -> String {
            "home-\(id)-\(region)"
        }

        /// Genre filter keyed by name (Jellyfin queries genres by name, not id).
        nonisolated static func genre(name: String) -> String {
            "home-genre-\(name)"
        }

        /// Generic tag filter; fallback for HomeRowType cases without a dedicated key.
        nonisolated static func tag(name: String) -> String {
            "home-tag-\(name)"
        }
    }

    enum Catalog {
        nonisolated static func streamingService(watchProviderID: Int, region: String) -> String {
            "streamingService-\(watchProviderID)-\(region)"
        }

        nonisolated static func tvNetwork(id: Int) -> String {
            "tvNetwork-\(id)"
        }

        nonisolated static func movieStudio(id: Int) -> String {
            "movieStudio-\(id)"
        }

        nonisolated static func movieGenre(id: Int) -> String {
            "movieGenre-\(id)"
        }

        nonisolated static func tvGenre(id: Int) -> String {
            "tvGenre-\(id)"
        }
    }
}
