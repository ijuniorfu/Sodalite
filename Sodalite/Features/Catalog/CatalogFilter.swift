import Foundation

/// Selector for a Jellyseerr filtered-discover page (genre, network, studio); plumbed through CatalogFilteredGridView's navigation destination to pick the Seerr endpoint and title.
enum CatalogFilter: Hashable, Sendable {
    case movieGenre(id: Int, name: String)
    case tvGenre(id: Int, name: String)
    case movieStudio(id: Int, name: String)
    case tvNetwork(id: Int, name: String)
    /// TMDB watch-providers filter returning both movies and TV; preferred over `.tvNetwork` for cross-medium streamers (Disney+, Netflix, Apple TV+) so the tile doesn't hide movies behind a TV-only network filter.
    case streamingService(tmdbWatchProviderID: Int, name: String, region: String)

    var displayName: String {
        switch self {
        case .movieGenre(_, let name),
             .tvGenre(_, let name),
             .movieStudio(_, let name),
             .tvNetwork(_, let name),
             .streamingService(_, let name, _):
            return name
        }
    }

    /// FilterCache key. Region is embedded for streaming services because TMDB watch-providers are region-scoped (Disney+ differs DE vs US), so cached pages must scope to their region.
    var cacheKey: String {
        switch self {
        case .movieGenre(let id, _): return FilterCacheKey.Catalog.movieGenre(id: id)
        case .tvGenre(let id, _): return FilterCacheKey.Catalog.tvGenre(id: id)
        case .movieStudio(let id, _): return FilterCacheKey.Catalog.movieStudio(id: id)
        case .tvNetwork(let id, _): return FilterCacheKey.Catalog.tvNetwork(id: id)
        case .streamingService(let id, _, let region):
            return FilterCacheKey.Catalog.streamingService(watchProviderID: id, region: region)
        }
    }
}
