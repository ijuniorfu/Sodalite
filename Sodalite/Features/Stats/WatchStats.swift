import Foundation

/// One genre and how many watched items fell under it.
struct GenreCount: Identifiable, Sendable, Equatable {
    let name: String
    let count: Int
    var id: String { name }
}

/// Aggregated watch statistics for the active user on the active server.
/// All figures are client-side aggregates of standard Jellyfin UserData;
/// `estimatedSeconds` is an estimate (sum of runtime over played items,
/// multiplied by play count to include rewatches).
struct WatchStats: Sendable, Equatable {
    var moviesWatched: Int
    var totalMovies: Int
    var episodesWatched: Int
    var totalEpisodes: Int
    /// Distinct series with at least one watched episode (from the scan).
    var seriesStarted: Int
    /// Series the server marks fully played (IsPlayed on the Series item).
    var seriesCompleted: Int
    var estimatedSeconds: Int64
    var topGenres: [GenreCount]
    var mostRewatched: [JellyfinItem]
    var recentlyWatched: [JellyfinItem]
    /// How many items the scan actually summed (for the "based on N" note).
    var scannedItemCount: Int
    /// True when the scan hit its hard cap before reaching the end.
    var scanCapped: Bool

    /// Fraction 0...1 of all movies+episodes that are played.
    var completionRate: Double {
        let total = totalMovies + totalEpisodes
        guard total > 0 else { return 0 }
        return Double(moviesWatched + episodesWatched) / Double(total)
    }

    var isEmpty: Bool { moviesWatched == 0 && episodesWatched == 0 }

    var estimatedHours: Int { Int(estimatedSeconds / 3600) }
    var estimatedDays: Double { Double(estimatedSeconds) / 86_400 }
}
