import Foundation

@Observable
@MainActor
final class WatchStatsViewModel {
    var stats: WatchStats?
    var errorMessage: String?
    /// Items summed so far during the scan, surfaced as live progress.
    var progressCount = 0

    let imageService: JellyfinImageService

    private let libraryService: JellyfinLibraryServiceProtocol
    private let userID: String

    private let pageSize = 500
    private let scanCap = 20_000

    init(
        libraryService: JellyfinLibraryServiceProtocol,
        imageService: JellyfinImageService,
        userID: String
    ) {
        self.libraryService = libraryService
        self.imageService = imageService
        self.userID = userID
    }

    func loadStats() async {
        errorMessage = nil
        progressCount = 0
        do {
            async let playedMovies = count(types: [.movie], playedOnly: true)
            async let totalMovies = count(types: [.movie], playedOnly: false)
            async let playedEpisodes = count(types: [.episode], playedOnly: true)
            async let totalEpisodes = count(types: [.episode], playedOnly: false)
            async let rewatched = fetchRail(sortBy: "PlayCount", rewatchedOnly: true)
            async let recent = fetchRail(sortBy: "DatePlayed", rewatchedOnly: false)

            let scan = try await runScan()

            stats = WatchStats(
                moviesWatched: try await playedMovies,
                totalMovies: try await totalMovies,
                episodesWatched: try await playedEpisodes,
                totalEpisodes: try await totalEpisodes,
                seriesStarted: scan.distinctSeries,
                estimatedSeconds: scan.seconds,
                topGenres: scan.topGenres,
                mostRewatched: try await rewatched,
                recentlyWatched: try await recent,
                scannedItemCount: scan.count,
                scanCapped: scan.capped
            )
        } catch is CancellationError {
            // View went away mid-load; leave state as-is.
        } catch {
            errorMessage = String(localized: "stats.error.generic", defaultValue: "Couldn't load your stats.")
        }
    }

    // MARK: - Cheap count

    private func count(types: [ItemType], playedOnly: Bool) async throws -> Int {
        var q = ItemQuery()
        q.includeItemTypes = types
        q.limit = 0
        q.fields = ""  // no per-item payload needed for a count
        if playedOnly { q.filters = ["IsPlayed"] }
        let resp = try await libraryService.getItems(userID: userID, query: q)
        return resp.totalRecordCount
    }

    // MARK: - Rails

    private func fetchRail(sortBy: String, rewatchedOnly: Bool) async throws -> [JellyfinItem] {
        var q = ItemQuery()
        q.includeItemTypes = [.movie, .episode]
        q.filters = ["IsPlayed"]
        q.sortBy = sortBy
        q.sortOrder = "Descending"
        q.limit = 12
        q.fields = JellyfinEndpoint.homeRowFields
        let resp = try await libraryService.getItems(userID: userID, query: q)
        if rewatchedOnly {
            // Genuine rewatches only, so the rail isn't just "everything watched".
            return resp.items.filter { ($0.userData?.playCount ?? 0) > 1 }
        }
        return resp.items
    }

    // MARK: - Heavy scan

    private struct ScanResult {
        var seconds: Int64
        var topGenres: [GenreCount]
        var distinctSeries: Int
        var count: Int
        var capped: Bool
    }

    private func runScan() async throws -> ScanResult {
        var seconds: Int64 = 0
        var genreCounts: [String: Int] = [:]
        var seriesIDs = Set<String>()
        var start = 0
        var capped = false

        while true {
            var q = ItemQuery()
            q.includeItemTypes = [.movie, .episode]
            q.filters = ["IsPlayed"]
            q.sortBy = "DatePlayed"
            q.sortOrder = "Descending"
            q.limit = pageSize
            q.startIndex = start
            q.fields = "Genres"  // runtime / seriesId / userData ride along free
            let resp = try await libraryService.getItems(userID: userID, query: q)
            if resp.items.isEmpty { break }

            for item in resp.items {
                let plays = Int64(max(item.userData?.playCount ?? 1, 1))
                if let ticks = item.runTimeTicks {
                    seconds += (ticks / 10_000_000) * plays
                }
                if let genres = item.genres {
                    for g in genres { genreCounts[g, default: 0] += 1 }
                }
                if item.type == .episode, let sid = item.seriesId {
                    seriesIDs.insert(sid)
                }
            }

            start += resp.items.count
            progressCount = start

            if start >= scanCap { capped = true; break }
            if start >= resp.totalRecordCount { break }
            if resp.items.count < pageSize { break }
        }

        let top = genreCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { GenreCount(name: $0.key, count: $0.value) }

        return ScanResult(
            seconds: seconds,
            topGenres: Array(top),
            distinctSeries: seriesIDs.count,
            count: start,
            capped: capped
        )
    }
}
