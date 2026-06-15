import SwiftUI

// MARK: - Per-Row Fetching

extension HomeViewModel {

    /// /Items/Latest with GroupItems (the server default) returns the
    /// bare Episode object when a series gained exactly one new
    /// episode; only multi-episode batches come back folded into their
    /// Series. The web client papers over this by rendering such
    /// episodes with the series poster and linking to the series.
    /// Sodalite's Latest rows are series-level, so replace each
    /// episode with its parent series (one batched Ids lookup) and
    /// dedupe in case the series is already in the row. On any lookup
    /// failure the row falls back to the unfolded items rather than
    /// going empty.
    private func foldEpisodesIntoSeries(_ items: [JellyfinItem]) async -> [JellyfinItem] {
        let seriesIDs = items.compactMap { $0.type == .episode ? $0.seriesId : nil }
        guard !seriesIDs.isEmpty else { return items }

        let query = ItemQuery(
            ids: Array(Set(seriesIDs)),
            fields: JellyfinEndpoint.homeRowFields
        )
        guard let response = try? await libraryService.getItems(userID: userID, query: query) else {
            return items
        }
        let seriesByID = Dictionary(
            response.items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var seen = Set<String>()
        var folded: [JellyfinItem] = []
        for item in items {
            let mapped: JellyfinItem
            if item.type == .episode, let seriesID = item.seriesId, let series = seriesByID[seriesID] {
                mapped = series
            } else {
                mapped = item
            }
            if seen.insert(mapped.id).inserted {
                folded.append(mapped)
            }
        }
        return folded
    }

    func loadRow(config: HomeRowConfig) async -> HomeRowData? {
        do {
            let type = config.type
            let items: [JellyfinItem]

            switch type {
            case .continueWatching:
                let response = try await libraryService.getResumeItems(userID: userID, mediaType: "Video", limit: 16)
                if HomeRowConfig.mergeContinueWatchingNextUp(serverID: serverID) {
                    // Plex-style combined row: resume items first, the
                    // Next Up episodes appended behind them. Next Up
                    // already excludes resumable episodes server-side
                    // (EnableResumable=false), the id dedupe is belt
                    // and suspenders. Next Up failing must not take
                    // the resume items down with it.
                    let rewatching = HomeRowConfig.enableRewatchingNextUp(serverID: serverID)
                    let nextUp = (try? await libraryService.getNextUp(userID: userID, seriesID: nil, limit: 16, rewatching: rewatching))?.items ?? []
                    var seen = Set(response.items.map(\.id))
                    items = response.items + nextUp.filter { seen.insert($0.id).inserted }
                } else {
                    items = response.items
                }

            case .nextUp:
                let rewatching = HomeRowConfig.enableRewatchingNextUp(serverID: serverID)
                let response = try await libraryService.getNextUp(userID: userID, seriesID: nil, limit: 16, rewatching: rewatching)
                items = response.items

            case .latestMovies:
                // Native /Items/Latest for Jellyfin parity, whatever
                // order the Jellyfin web UI shows is what Sodalite
                // shows. ParentId omitted so users with multiple
                // movie libraries (Movies + Documentaries + Kids …)
                // see fresh content from every source; without the
                // parent-id hint we MUST pass IncludeItemTypes=Movie,
                // otherwise Jellyfin returns a mix of movies,
                // series, and music jumbled into one row.
                items = try await libraryService.getLatestMedia(
                    userID: userID,
                    parentID: nil,
                    includeItemTypes: [.movie],
                    limit: 16
                )

            case .latestShows:
                // Per-library fan-out instead of one typed aggregate
                // query. The aggregate needed IncludeItemTypes=
                // Series,Episode (Series alone misses shows that only
                // gained episodes, the filter applies before
                // grouping), but WITH the explicit type filter the
                // server's episode grouping is unreliable, so episode
                // bursts from a few shows crowded everything else out
                // of the fetch window no matter the over-fetch
                // (Vincent device reports, 2026-06-11). ParentId-only
                // queries are the semantics the per-library rows have
                // used reliably since Sodalite#12: grouping works,
                // every shows library is represented. Lists arrive
                // newest-first per library; round-robin interleave
                // approximates global recency (item DateCreated can't
                // sort this: a grouped entry carries the SERIES'
                // creation date, not the new episode's).
                let showLibraries = videoLibraries.filter { ($0.collectionType ?? "") == "tvshows" }
                if showLibraries.isEmpty {
                    // Library list unavailable (getLibraries failed):
                    // fall back to the typed aggregate, imperfect but
                    // better than an empty row.
                    let latest = try await libraryService.getLatestMedia(
                        userID: userID,
                        parentID: nil,
                        includeItemTypes: [.series, .episode],
                        limit: 64
                    )
                    items = Array(await foldEpisodesIntoSeries(latest).prefix(16))
                } else {
                    var lists: [[JellyfinItem]] = []
                    for library in showLibraries {
                        let list = (try? await libraryService.getLatestMedia(
                            userID: userID,
                            parentID: library.id,
                            includeItemTypes: nil,
                            limit: 16
                        )) ?? []
                        lists.append(list)
                    }
                    var merged: [JellyfinItem] = []
                    let deepest = lists.map(\.count).max() ?? 0
                    for index in 0..<deepest {
                        for list in lists where index < list.count {
                            merged.append(list[index])
                        }
                    }
                    items = Array(await foldEpisodesIntoSeries(merged).prefix(16))
                }

            case .allMovies:
                let query = ItemQuery(
                    includeItemTypes: [.movie],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .allSeries:
                let query = ItemQuery(
                    includeItemTypes: [.series],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .favorites:
                let query = ItemQuery(
                    includeItemTypes: [.movie, .series, .boxSet],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    isFavorite: true,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .topRatedMovies:
                let query = ItemQuery(
                    includeItemTypes: [.movie],
                    sortBy: "CommunityRating",
                    sortOrder: "Descending",
                    limit: 20,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .topRatedShows:
                let query = ItemQuery(
                    includeItemTypes: [.series],
                    sortBy: "CommunityRating",
                    sortOrder: "Descending",
                    limit: 20,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .recentlyAdded:
                let query = ItemQuery(
                    includeItemTypes: [.movie, .series],
                    sortBy: "DateCreated",
                    sortOrder: "Descending",
                    limit: 20,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .collections:
                let query = ItemQuery(
                    includeItemTypes: [.boxSet],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .playlists:
                let query = ItemQuery(
                    includeItemTypes: [.playlist],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .libraryLatest:
                // Per-library Latest: scope /Items/Latest to this
                // library via parentID alone, exactly like the Jellyfin
                // web client's per-library Latest row.
                //
                // We deliberately do NOT pass IncludeItemTypes here.
                // The endpoint defaults to GroupItems=true, which folds
                // freshly added episodes up into their parent series.
                // Forcing IncludeItemTypes=Series made the server filter
                // to Series-typed rows *before* grouping, so a library
                // whose recent additions were all episodes of one show
                // collapsed to a single tile (Sodalite#12, DrHurt:
                // "latest in Series - French only loads 1 item"). Movie
                // libraries never showed the symptom because movies have
                // nothing to group into. ParentId already constrains the
                // row to this library's content, so the type hint that
                // the aggregate latestMovies/latestShows rows need (they
                // drop ParentId) is not just unnecessary here, it's the
                // bug.
                guard let libraryID = config.libraryID else { return nil }
                // Mild over-fetch with a post-fold cap, same rationale
                // as latestShows: the fold can dedupe a series object
                // against its own episode entries, shrinking the row
                // below the intended 16.
                let latest = try await libraryService.getLatestMedia(
                    userID: userID,
                    parentID: libraryID,
                    includeItemTypes: nil,
                    limit: 24
                )
                items = Array(await foldEpisodesIntoSeries(latest).prefix(16))

            case .myMedia, .genres, .discoverProviders:
                return nil
            }

            return HomeRowData(
                type: type,
                items: items,
                libraryID: config.libraryID,
                libraryName: config.libraryName
            )
        } catch {
            return nil
        }
    }

    func loadTagRow(type: HomeRowType) async -> HomeTagRowData? {
        do {
            let tags: [NamedItem]
            switch type {
            case .genres:
                let allGenres = try await libraryService.getGenres(userID: userID)
                tags = allGenres.filter { GenreFilter.isPrimary($0.name) }
            default:
                return nil
            }

            // Fetch one item per tag in parallel for matching backdrops
            let tagItems: [(String, JellyfinItem?)] = await withTaskGroup(
                of: (String, JellyfinItem?).self,
                returning: [(String, JellyfinItem?)].self
            ) { group in
                // Bounded fan-out: one backdrop query per genre, but at
                // most `maxConcurrent` enqueued at a time instead of all
                // ~15-20 up front, so a genre-heavy library doesn't pile
                // a burst onto the HTTPClient limiter on first load.
                var iter = tags.makeIterator()
                let maxConcurrent = 6

                func enqueue(_ tag: NamedItem) {
                    group.addTask {
                        let query = ItemQuery(
                            includeItemTypes: [.movie, .series],
                            sortBy: "Random",
                            limit: 1,
                            genres: [tag.name],
                            fields: JellyfinEndpoint.homeRowFields
                        )
                        let item = try? await self.libraryService.getItems(userID: self.userID, query: query).items.first
                        return (tag.id, item)
                    }
                }

                for _ in 0..<maxConcurrent {
                    guard let next = iter.next() else { break }
                    enqueue(next)
                }
                var results: [(String, JellyfinItem?)] = []
                for await result in group {
                    results.append(result)
                    if let next = iter.next() { enqueue(next) }
                }
                return results
            }

            // Build cards on MainActor (image URL construction needs it)
            let itemMap = Dictionary(uniqueKeysWithValues: tagItems)
            let cardData: [TagCardData] = tags.map { tag in
                let item = itemMap[tag.id].flatMap { $0 }
                let backdropURL = item.flatMap { imageService.backdropURL(for: $0) ?? imageService.posterURL(for: $0) }
                return TagCardData(id: tag.id, name: tag.name, backdropURL: backdropURL)
            }

            return HomeTagRowData(type: type, tags: cardData)
        } catch {
            return nil
        }
    }
}
