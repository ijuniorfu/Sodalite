import SwiftUI

// MARK: - Background Precompute

extension HomeViewModel {

    /// Resolves every CatalogProviders.networks tile against the
    /// local library + (where available) TMDB watch-providers, in
    /// the background, so the home-view filter can drop empty
    /// tiles automatically. Each provider's full result list is
    /// also written to FilterCache so a subsequent tap renders the
    /// grid synchronously.
    ///
    /// Throttled to one run per session, re-running every Home
    /// re-appearance would fire ~110 Seerr calls and add nothing
    /// the user can perceive in that window. Storage state (cache
    /// + counts dict) survives across appearances anyway.
    func precomputeProviderCounts() async {
        if providerCountsComputedAt != nil { return }
        // NOTE: the once-per-session latch is set at the END of the
        // write pass, not here. Latching up front meant a cancelled or
        // failed run (loadContent re-entry inside the precompute's
        // multi-second runtime is common: 60 s staleness, playback
        // stop, favorites change) left the latch set and the
        // replacement task bailed instantly, ending the session with
        // partial or empty provider counts.

        let region = Locale.current.region?.identifier ?? "US"
        let lib = libraryService
        let disc = discoverService
        let uid = userID

        // Build the TMDB map on MainActor first, JellyfinItem.tmdbID
        // and CatalogProviders.networks are both MainActor-isolated
        // under the project's default isolation, so we have to read
        // them here before handing the values to a detached task.
        // Slim fields even on the heaviest query the app makes (a
        // 10 000-item all-library scan). We only read tmdbID off these
        // items to build the provider match map, plus an image tag for
        // the sample backdrop, so ProviderIds + the home image tags is
        // all we need. Pulling defaultFields here meant People /
        // MediaStreams / MediaSources / Chapters for every item in the
        // library, by far the biggest download on Home (Sodalite#12).
        let allItemsQuery = ItemQuery(
            includeItemTypes: [.movie, .series],
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 10000,
            fields: JellyfinEndpoint.homeRowFields + ",ProviderIds"
        )
        // Honest failure handling: a failed or cancelled scan must NOT
        // proceed with an empty tmdbMap, the resolve pass would then
        // find studio-only matches and overwrite good FilterCache
        // entries with shrunken lists (providers whose matches come
        // only via the TMDB augment, like Paramount+, would count 0
        // and their tile would hide for the session).
        guard let allItems = try? await libraryService.getItems(
            userID: userID, query: allItemsQuery
        ).items, !Task.isCancelled else { return }

        var tmdbMap: [Int: JellyfinItem] = [:]
        for item in allItems {
            if let id = item.tmdbID { tmdbMap[id] = item }
        }
        // Snapshot only the fields the resolve pass needs into a
        // plain Sendable struct, CatalogProvider itself is
        // MainActor-isolated under the project default, so we can't
        // hand the struct directly to a detached task.
        let providerInfos: [ProviderResolveInfo] = CatalogProviders.networks.map {
            ProviderResolveInfo(
                id: $0.id,
                studioNames: $0.jellyfinStudioNames,
                watchProviderID: $0.tmdbWatchProviderID
            )
        }
        let mapForTask = tmdbMap

        // Resolve passes runs in a detached task so the task-group
        // closures it spawns don't inherit MainActor isolation.
        let resolved: [(Int, [JellyfinItem])] = await Task.detached(priority: .utility) {
            await withTaskGroup(
                of: (Int, [JellyfinItem]).self,
                returning: [(Int, [JellyfinItem])].self
            ) { group in
                var iter = providerInfos.makeIterator()
                let maxConcurrent = 4

                for _ in 0..<maxConcurrent {
                    guard let info = iter.next() else { break }
                    group.addTask {
                        let items = await Self.resolveProviderItems(
                            info: info, region: region,
                            tmdbMap: mapForTask,
                            libraryService: lib, discoverService: disc, userID: uid
                        )
                        return (info.id, items)
                    }
                }
                var collected: [(Int, [JellyfinItem])] = []
                while let result = await group.next() {
                    collected.append(result)
                    if let next = iter.next() {
                        group.addTask {
                            let items = await Self.resolveProviderItems(
                                info: next, region: region,
                                tmdbMap: mapForTask,
                                libraryService: lib, discoverService: disc, userID: uid
                            )
                            return (next.id, items)
                        }
                    }
                }
                return collected
            }
        }.value

        // The detached resolve doesn't inherit this task's
        // cancellation; a cancelled precompute must not write its
        // (possibly superseded) results over the replacement run's.
        guard !Task.isCancelled else { return }

        // MainActor pass: write counts + cache + sample backdrop
        // for each provider.
        for (providerID, items) in resolved {
            providerItemCounts[providerID] = items.count
            FilterCache.shared.setHomeFilterItems(
                items,
                filterKey: FilterCacheKey.Home.provider(id: providerID, region: region)
            )
            // Backfill the backdrop only if the fast studio-only
            // pass didn't already set one, the precompute resolver
            // includes watch-provider matches, so it can find a
            // sample for tiles whose Studios tag in the library
            // doesn't match (Paramount+ in particular).
            if providerBackdrops[providerID] == nil,
               let sample = items.first,
               let url = imageService.backdropURL(for: sample)
                   ?? imageService.posterURL(for: sample) {
                providerBackdrops[providerID] = url
            }
        }

        // Latch only after a fully-written pass (see the note at the
        // top of this function).
        providerCountsComputedAt = Date()
    }

    /// Pre-warms FilterCache for every genre tile currently on the
    /// home page so the first tap on `Action`, `Comedy`, … renders
    /// straight from disk instead of going through a Jellyfin Studios
    /// roundtrip. Mirrors the provider precompute pattern: detached
    /// task group with a small concurrency cap, throttled to one run
    /// per session. The grid views still refresh against the server
    /// when opened (stale-while-revalidate), this just paints the
    /// first frame instantly. Gated by `genreCachesComputedAt` so
    /// repeated Home re-appearances within a session don't re-run.
    func precomputeGenreCaches() async {
        if genreCachesComputedAt != nil { return }
        // Guard against an all-empty genres row. Since the gating
        // rework this task is scheduled at the END of loadContent
        // (+13 s), AFTER tagRows is published, so the old "races
        // loadContent from the same detach point" rationale no longer
        // applies; the empty-bail simply lets the next Home appearance
        // retry when the genres row genuinely had nothing yet.
        let genreNames: [String] = tagRows
            .filter { $0.type == .genres }
            .flatMap { $0.tags.map(\.name) }
        if genreNames.isEmpty { return }

        let lib = libraryService
        let uid = userID

        let resolved: [(String, [JellyfinItem])] = await Task.detached(priority: .utility) {
            await withTaskGroup(
                of: (String, [JellyfinItem]).self,
                returning: [(String, [JellyfinItem])].self
            ) { group in
                var iter = genreNames.makeIterator()
                let maxConcurrent = 4

                func enqueue(_ name: String) {
                    group.addTask {
                        let query = ItemQuery(
                            includeItemTypes: [.movie, .series],
                            sortBy: "SortName",
                            sortOrder: "Ascending",
                            limit: 50,
                            genres: [name],
                            fields: JellyfinEndpoint.homeRowFields
                        )
                        let items = (try? await lib.getItems(
                            userID: uid, query: query
                        ).items) ?? []
                        return (name, items)
                    }
                }

                for _ in 0..<maxConcurrent {
                    guard let next = iter.next() else { break }
                    enqueue(next)
                }
                var collected: [(String, [JellyfinItem])] = []
                while let result = await group.next() {
                    collected.append(result)
                    if let next = iter.next() { enqueue(next) }
                }
                return collected
            }
        }.value

        // A cancelled pass (loadContent re-entry, VM teardown) must not
        // persist results resolved for a config that just changed, and
        // must not latch: leaving genreCachesComputedAt nil lets the
        // next Home appearance run the precompute to completion.
        guard !Task.isCancelled else { return }

        // Hop back to MainActor for the cache writes, FilterCache.shared
        // is non-isolated but the detached closure can't see that under
        // the project's strict-concurrency settings, so we collect the
        // results first and persist here.
        for (name, items) in resolved where !items.isEmpty {
            FilterCache.shared.setHomeFilterItems(
                items, filterKey: FilterCacheKey.Home.genre(name: name)
            )
        }
        // Latch at the END: setting it up front meant a cancelled run
        // marked the session "computed" with nothing in the cache.
        genreCachesComputedAt = Date()
    }

    /// Sendable snapshot of the fields `resolveProviderItems` reads
    /// off a `CatalogProvider`. Needed because CatalogProvider
    /// itself is MainActor-isolated under the project default and
    /// the resolve pass runs in a detached task.
    struct ProviderResolveInfo: Sendable {
        let id: Int
        let studioNames: [String]
        let watchProviderID: Int?
    }

    /// Resolves a single provider's library items: studio-name match
    /// (always) plus TMDB watch-provider augment (when the provider
    /// has a watch-provider id). Returns the merged + deduped list,
    /// alphabetically ordered after the studio matches. Static so
    /// the precompute task group doesn't have to capture `self`.
    private static func resolveProviderItems(
        info: ProviderResolveInfo,
        region: String,
        tmdbMap: [Int: JellyfinItem],
        libraryService: JellyfinLibraryServiceProtocol,
        discoverService: SeerrDiscoverServiceProtocol?,
        userID: String
    ) async -> [JellyfinItem] {
        let studioQuery = ItemQuery(
            includeItemTypes: [.movie, .series],
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 200,
            studioNames: info.studioNames,
            fields: JellyfinEndpoint.homeRowFields
        )
        let studioItems = (try? await libraryService.getItems(
            userID: userID, query: studioQuery
        ).items) ?? []

        var phase2Items: [JellyfinItem] = []
        if let watchID = info.watchProviderID, let discover = discoverService {
            let providerTmdbIDs = await discover.collectWatchProviderTmdbIDs(
                providerID: watchID, region: region
            )
            phase2Items = providerTmdbIDs.compactMap { tmdbMap[$0] }
        }

        return ProviderMatchMerging.merge(phase1: studioItems, phase2: phase2Items)
    }

    func loadProviderBackdrops() async {
        // Only providers without a resolved backdrop. loadContent
        // re-fires on every playback stop / favorites change / 60 s
        // staleness, and unlike the counts/genre passes this one had
        // no per-session throttle, so it re-ran all ~33 random-sample
        // queries each time mostly to overwrite hero images that were
        // already resolved.
        let providers = CatalogProviders.networks.filter { providerBackdrops[$0.id] == nil }
        guard !providers.isEmpty else { return }
        // Stage 1: collect a sample item per provider in parallel.
        // imageService isn't Sendable, so URL construction happens
        // back on MainActor in stage 2, the task group only carries
        // the JellyfinItem (which is Sendable) across the boundary.
        let pairs: [(Int, JellyfinItem)] = await withTaskGroup(
            of: (Int, JellyfinItem?).self,
            returning: [(Int, JellyfinItem)].self
        ) { group in
            // Bounded fan-out: keep at most `maxConcurrent` provider
            // queries enqueued at once rather than spawning all ~33 up
            // front. The HTTPClient limiter caps in-flight requests
            // regardless, this just avoids stacking dozens of suspended
            // tasks that would all pile onto that limiter at once.
            var iter = providers.makeIterator()
            let maxConcurrent = 6

            func enqueue(_ provider: CatalogProvider) {
                group.addTask { [libraryService, userID] in
                    let query = ItemQuery(
                        includeItemTypes: [.movie, .series],
                        sortBy: "Random",
                        limit: 1,
                        studioNames: provider.jellyfinStudioNames,
                        fields: JellyfinEndpoint.homeRowFields
                    )
                    let item = try? await libraryService.getItems(userID: userID, query: query).items.first
                    return (provider.id, item)
                }
            }

            for _ in 0..<maxConcurrent {
                guard let next = iter.next() else { break }
                enqueue(next)
            }
            var collected: [(Int, JellyfinItem)] = []
            for await (id, item) in group {
                if let item { collected.append((id, item)) }
                if let next = iter.next() { enqueue(next) }
            }
            return collected
        }
        for (id, item) in pairs {
            if let url = imageService.backdropURL(for: item) ?? imageService.posterURL(for: item) {
                providerBackdrops[id] = url
            }
        }
    }
}
