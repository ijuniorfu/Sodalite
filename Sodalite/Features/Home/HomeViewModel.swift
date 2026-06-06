import SwiftUI

@Observable
final class HomeViewModel {
    var rows: [HomeRowData] = []
    var tagRows: [HomeTagRowData] = []
    var isLoading = true
    var errorMessage: String?
    var rowConfigs: [HomeRowConfig] = []
    var needsReload = false
    /// Sample backdrop URL per streaming-provider TMDB id, populated
    /// from a one-shot Jellyfin Studios query so each provider tile
    /// can show a hero image of an actual library item rather than a
    /// flat dark plate. Empty values are kept as `nil` so the tile
    /// gracefully falls back to the logo-only style.
    var providerBackdrops: [Int: URL] = [:]

    /// Resolved-item count per streaming provider, keyed by
    /// `provider.id`. Populated by the background precompute pass,
    /// the empty-tile-hide filter on the home view reads from here
    /// to drop providers whose library matches resolve to zero
    /// without waiting for the user to tap each one.
    var providerItemCounts: [Int: Int] = [:]

    /// Guards against concurrent / repeated precompute runs within
    /// the same session, re-resolving every provider on every Home
    /// re-appearance would hammer Seerr for ~100 calls and add
    /// nothing the user can perceive.
    private var providerCountsComputedAt: Date?

    /// Same throttle as `providerCountsComputedAt`, but for the
    /// genre-tile pre-warm pass. The grids themselves still revalidate
    /// against the server when opened, this just means the *first*
    /// frame after a tap is already painted from the file cache.
    private var genreCachesComputedAt: Date?

    /// Handles for the background side-effects `loadContent` kicks
    /// off. Held so we can cancel them when the view model is torn
    /// down (profile switch, tab destruction) or when `loadContent`
    /// is re-entered before the previous fan-out finished, without
    /// that, an orphaned VM keeps fetching against the server and
    /// writing into FilterCache long after the UI it backed is gone.
    private var backdropTask: Task<Void, Never>?
    private var providerCountsTask: Task<Void, Never>?
    private var genreCachesTask: Task<Void, Never>?

    /// Timestamp of the last successful loadContent(). Used by the
    /// view's onAppear to decide whether enough time has passed to
    /// refresh, otherwise new server-side content (Latest Movies,
    /// Latest Series, etc.) never shows up until the app restarts.
    var lastLoadedAt: Date?

    /// Bumped on every loadContent entry; the for-await loop checks
    /// this before publishing each row so a re-entrant loadContent
    /// (profile switch, refresh-while-loading) supersedes the older
    /// run instead of letting both write into rows/tagRows.
    private var loadGeneration: Int = 0

    private let libraryService: JellyfinLibraryServiceProtocol
    private let imageService: JellyfinImageService
    private let discoverService: SeerrDiscoverServiceProtocol?
    private let userID: String
    private let serverID: String
    /// Video libraries (movies / tvshows / homevideos / mixed) used to
    /// render the My Media row. Populated by loadContent().
    var videoLibraries: [JellyfinLibrary] = []

    init(
        libraryService: JellyfinLibraryServiceProtocol,
        imageService: JellyfinImageService,
        discoverService: SeerrDiscoverServiceProtocol? = nil,
        userID: String,
        serverID: String
    ) {
        self.libraryService = libraryService
        self.imageService = imageService
        self.discoverService = discoverService
        self.userID = userID
        self.serverID = serverID
        self.rowConfigs = HomeRowConfig.loadFromStorage(serverID: serverID)
    }

    func loadContent() async {
        loadGeneration += 1
        let myGen = loadGeneration

        let isFirstLoad = rows.isEmpty && tagRows.isEmpty
        if isFirstLoad {
            isLoading = true
        }
        errorMessage = nil

        // Pull the server's libraries so per-library Latest rows and
        // the My Media row reflect what's actually on this server.
        // Reconciliation is additive and preserves the user's toggles
        // and order; we only persist when the fetch succeeds so a
        // transient failure can't wipe the dynamic rows.
        if let libraries = try? await libraryService.getLibraries(userID: userID) {
            let videoTypes: Set<String> = ["movies", "tvshows", "homevideos", "mixed"]
            videoLibraries = libraries.filter { videoTypes.contains($0.collectionType ?? "") }
            let reconciled = HomeRowConfig.reconciled(stored: rowConfigs, libraries: libraries)
            if reconciled != rowConfigs {
                rowConfigs = reconciled
                HomeRowConfig.saveToStorage(reconciled, serverID: serverID)
            }
        } else {
            LogTap.shared.note("Home: getLibraries failed, falling back to aggregated Latest rows")
        }

        let enabledRows = rowConfigs
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }

        // Fan out every row's network call in parallel. The
        // sequential `for await` walk used to mean each row started
        // only after the previous one returned, so a 7-row config
        // took roughly 7× the slowest call. Tasks come back in
        // completion order; orderedSections() drives display order
        // from the config sortOrder, so arrival order doesn't affect
        // layout, only paint timing.
        enum RowResult: Sendable {
            case media(HomeRowData)
            case tag(HomeTagRowData)
            case empty
        }

        // Capture row-type predicates on MainActor before crossing
        // into the task group, HomeRowType is MainActor-isolated
        // under the project's default-isolation rule, so reading
        // .isTagRow from a non-isolated closure would otherwise be
        // rejected.
        // Carry the full config (not just the type) so per-library
        // rows keep their libraryID/name/collectionType into loadRow,
        // and so identity stays unique per library. isTagRow is
        // precomputed here on MainActor (alongside the config) so the
        // task-group closures below never have to read the
        // MainActor-isolated HomeRowType predicate themselves.
        let plan: [(config: HomeRowConfig, isTag: Bool)] = enabledRows.compactMap { config in
            if config.type.isDiscoverProviderRow { return nil }
            // My Media renders from videoLibraries directly; nothing to
            // fetch in the row fan-out.
            if config.type == .myMedia { return nil }
            return (config, config.type.isTagRow)
        }

        let plannedMediaIDs = Set(plan.filter { !$0.isTag }.map(\.config.id))
        let plannedTagIDs = Set(plan.filter { $0.isTag }.map(\.config.id))

        // Drop any rows whose config was disabled since the previous
        // load so the disappearance is instant rather than waiting on
        // the new fan-out to finish. Stale rows for still-enabled
        // types stay on screen and get replaced in-place as their
        // fresh result lands.
        rows.removeAll { !plannedMediaIDs.contains($0.id) }
        tagRows.removeAll { !plannedTagIDs.contains($0.id) }

        var sawAnyResult = false

        // Progressive publish: upsert each row as its fetch completes
        // instead of awaiting the full TaskGroup before swapping.
        // On a slow CDN-backed Jellyfin, fast rows (Continue Watching,
        // a few hundred ms) paint immediately while the slowest call
        // (Latest Movies/Series on a 1 PB library, 10+ s) keeps
        // streaming. ForEach diffs by HomeRowData.id (type rawValue),
        // so replacing a row in place preserves AsyncImage state for
        // subviews that were already mounted; new rows insert at the
        // position orderedSections() places them.
        await withTaskGroup(of: RowResult.self) { group in
            for entry in plan {
                let config = entry.config
                let isTag = entry.isTag
                let type = config.type
                group.addTask { [weak self] in
                    guard let self else { return .empty }
                    if isTag {
                        if let tagRow = await self.loadTagRow(type: type), !tagRow.tags.isEmpty {
                            return .tag(tagRow)
                        }
                    } else {
                        if let rowData = await self.loadRow(config: config), !rowData.items.isEmpty {
                            return .media(rowData)
                        }
                    }
                    return .empty
                }
            }
            for await result in group {
                // Stale guard: a newer loadContent has superseded
                // this one; drop the rest of its results on the floor
                // so we don't fight the newer run for the rows array.
                guard loadGeneration == myGen else { return }
                switch result {
                case .media(let row):
                    if let idx = rows.firstIndex(where: { $0.id == row.id }) {
                        rows[idx] = row
                    } else {
                        rows.append(row)
                    }
                    sawAnyResult = true
                    isLoading = false
                    errorMessage = nil
                case .tag(let row):
                    if let idx = tagRows.firstIndex(where: { $0.id == row.id }) {
                        tagRows[idx] = row
                    } else {
                        tagRows.append(row)
                    }
                    sawAnyResult = true
                    isLoading = false
                    errorMessage = nil
                case .empty:
                    break
                }
            }
        }

        guard loadGeneration == myGen else { return }

        // Total-failure path: every fan-out came back empty or threw.
        // loadRow/loadTagRow swallow errors and return nil, so "all
        // nils" looks the same as "server unreachable". Surface the
        // retry overlay only on a first load; on refresh we keep
        // whatever rows are already on screen so a transient CDN
        // hiccup doesn't wipe the home page.
        let hadConfiguredFetchableRows = !plan.isEmpty
        if hadConfiguredFetchableRows && !sawAnyResult && isFirstLoad {
            errorMessage = String(
                localized: "home.error.unreachable",
                defaultValue: "Couldn't reach your server. Check the connection and try again."
            )
            isLoading = false
            return
        }

        isLoading = false
        lastLoadedAt = .now

        // Cancel any previous fan-outs before kicking new ones off:
        // a rapid profile switch / notification-driven reload would
        // otherwise stack 2× the network calls and 2× the FilterCache
        // writes, with the older task scribbling stale data over the
        // newer one if it finished last.
        backdropTask?.cancel()
        providerCountsTask?.cancel()
        genreCachesTask?.cancel()
        backdropTask = nil
        providerCountsTask = nil
        genreCachesTask = nil

        // Gate each background pass on its consuming row being enabled.
        // The provider precompute is the heaviest query the app makes
        // (one 10 000-item all-library scan plus 33 per-provider
        // resolves), and the Discover row is the *only* thing that
        // reads its output, so firing it when the user has hidden that
        // row is pure waste, on a slow CDN-backed Jellyfin (Sodalite#12)
        // it's waste the user pays for in backend contention. Hiding the
        // Discover / Genres row in Customize now genuinely stops the
        // scan rather than just hiding tiles that were resolved anyway.
        let providersEnabled = enabledRows.contains { $0.type.isDiscoverProviderRow }
        let genresEnabled = enabledRows.contains { $0.type == .genres }

        // All three background passes deferred so the server isn't
        // hammered with secondary queries right as the user is
        // tapping into their first detail page. On a fast homelab
        // Jellyfin this delay is imperceptible (the user is still
        // looking at the rows); on a slow CDN-backed Jellyfin
        // (Sodalite#12) it keeps the backend free for whatever the
        // user does next instead of forcing the heavy precompute
        // queries to compete with their navigation. .utility
        // priority drops these below user-initiated work in the
        // Swift cooperative scheduler too.

        // Best-effort: fan out one Studios query per provider so
        // the streaming-provider row can render a sample backdrop
        // from the local library. Failures and gaps in metadata
        // are tolerated, the tile falls back to the logo-only
        // style for any provider that doesn't resolve.
        if providersEnabled {
            backdropTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await self?.loadProviderBackdrops()
            }
        }
        // Pre-resolve every provider tile in the background so the
        // empty-tile-hide pass on the home view has data to act on
        // *before* the user has tapped each one. Throttled to one
        // run per session. Heaviest of the three (one 10 000-item
        // all-library query plus per-provider studio + TMDB matches),
        // deferred longest.
        if providersEnabled {
            providerCountsTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { return }
                await self?.precomputeProviderCounts()
            }
        }
        // Pre-warm the genre tile grids the same way: one Studios
        // query per genre so the first tap renders straight from the
        // cache instead of paying a network roundtrip. Staggered well
        // behind the provider-counts pass (which itself fires a single
        // 10 000-item query plus per-provider resolves) so the two
        // heaviest background passes don't land on the HTTPClient
        // limiter at the same instant and starve each other on a slow
        // CDN origin (Sodalite#12).
        if genresEnabled {
            genreCachesTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(13))
                if Task.isCancelled { return }
                await self?.precomputeGenreCaches()
            }
        }
    }

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
        providerCountsComputedAt = Date()

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
        let allItems = (try? await libraryService.getItems(
            userID: userID, query: allItemsQuery
        ).items) ?? []

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
        // Wait until tagRows is populated. loadContent + this method
        // are both kicked off from the same Task.detached point so
        // they can race; if loadContent hasn't finished yet, just
        // bail and let the next caller (or the next Home appearance)
        // pick it up. Cheap enough that we don't bother retrying.
        let genreNames: [String] = tagRows
            .filter { $0.type == .genres }
            .flatMap { $0.tags.map(\.name) }
        if genreNames.isEmpty { return }
        genreCachesComputedAt = Date()

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

        // Hop back to MainActor for the cache writes, FilterCache.shared
        // is non-isolated but the detached closure can't see that under
        // the project's strict-concurrency settings, so we collect the
        // results first and persist here.
        for (name, items) in resolved where !items.isEmpty {
            FilterCache.shared.setHomeFilterItems(
                items, filterKey: FilterCacheKey.Home.genre(name: name)
            )
        }
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

        let phase1IDs = Set(studioItems.map(\.id))
        let extras = phase2Items
            .filter { !phase1IDs.contains($0.id) }
            .sorted { $0.name < $1.name }
        return studioItems + extras
    }

    private func loadProviderBackdrops() async {
        let providers = CatalogProviders.networks
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

    private func loadRow(config: HomeRowConfig) async -> HomeRowData? {
        do {
            let type = config.type
            let items: [JellyfinItem]

            switch type {
            case .continueWatching:
                let response = try await libraryService.getResumeItems(userID: userID, mediaType: "Video", limit: 16)
                items = response.items

            case .nextUp:
                let response = try await libraryService.getNextUp(userID: userID, seriesID: nil, limit: 16)
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
                // Same treatment as latestMovies, /Items/Latest
                // across every accessible library, typed down to
                // Series so we don't get movies/music mixed in.
                items = try await libraryService.getLatestMedia(
                    userID: userID,
                    parentID: nil,
                    includeItemTypes: [.series],
                    limit: 16
                )

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
                items = try await libraryService.getLatestMedia(
                    userID: userID,
                    parentID: libraryID,
                    includeItemTypes: nil,
                    limit: 16
                )

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

    private func loadTagRow(type: HomeRowType) async -> HomeTagRowData? {
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

    func imageURL(for item: JellyfinItem, rowType: HomeRowType, useSeriesArt: Bool = false) -> URL? {
        if rowType.usesBackdrop {
            // Continue Watching / Up Next. With the series-art preference on,
            // show the show's landscape Thumb (addressed by series id,
            // tagless) instead of the episode video-frame; the caller pairs
            // this with fallbackImageURL so a Thumb-less show degrades to the
            // still.
            if useSeriesArt {
                let id = (item.type == .episode ? item.seriesId : nil) ?? item.id
                return imageService.imageURL(itemID: id, imageType: .thumb, maxWidth: 720)
            }
            if item.type == .episode {
                return imageService.episodeThumbnailURL(for: item)
            }
            return imageService.backdropURL(for: item) ?? imageService.posterURL(for: item)
        }
        return imageService.posterURL(for: item)
    }

    /// The default Continue Watching / Up Next image (episode video-frame
    /// or backdrop). Used as the fallback under `imageURL(useSeriesArt:)`
    /// so a show with no Thumb still shows something.
    func fallbackImageURL(for item: JellyfinItem) -> URL? {
        if item.type == .episode {
            return imageService.episodeThumbnailURL(for: item)
        }
        return imageService.backdropURL(for: item) ?? imageService.posterURL(for: item)
    }

    func reloadConfig() {
        rowConfigs = HomeRowConfig.loadFromStorage(serverID: serverID)
    }

    /// Called by HomeView when the active server changes. Clears
    /// in-memory carousels so a partial render from the previous
    /// server's posters doesn't show while the new server's rows
    /// are loading, then runs a full content reload. The throttle
    /// guards (providerCountsComputedAt, genreCachesComputedAt) are
    /// also reset so the background precompute reruns for the new
    /// server's library.
    @MainActor
    func reloadAfterServerSwitch() async {
        // Flip into loading state before clearing rows so HomeView
        // lands in the spinner branch, not the empty no-content branch.
        isLoading = true
        rows = []
        tagRows = []
        providerBackdrops = [:]
        providerItemCounts = [:]
        providerCountsComputedAt = nil
        genreCachesComputedAt = nil
        lastLoadedAt = nil
        await loadContent()
    }

    /// Returns the ordered list of all sections (media rows + tag rows + discover) in config order
    func orderedSections() -> [HomeSection] {
        let enabledConfigs = rowConfigs
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }

        return enabledConfigs.compactMap { config in
            if config.type.isDiscoverProviderRow {
                return .discoverProviders
            }
            if config.type == .myMedia {
                return videoLibraries.isEmpty ? nil : .libraries(videoLibraries)
            }
            if config.type.isTagRow {
                if let tagRow = tagRows.first(where: { $0.type == config.type }) {
                    return .tags(tagRow)
                }
            } else {
                if let row = rows.first(where: { $0.id == config.id }) {
                    return .media(row)
                }
            }
            return nil
        }
    }
}

enum HomeSection: Identifiable {
    case media(HomeRowData)
    case tags(HomeTagRowData)
    case discoverProviders
    case libraries([JellyfinLibrary])

    var id: String {
        switch self {
        case .media(let data): data.id
        case .tags(let data): data.id
        case .discoverProviders: "discoverProviders"
        case .libraries: "myMedia"
        }
    }
}

struct HomeRowData: Identifiable, Sendable {
    let type: HomeRowType
    let items: [JellyfinItem]
    var libraryID: String? = nil
    var libraryName: String? = nil

    var id: String {
        if type == .libraryLatest, let libraryID {
            return "libraryLatest:\(libraryID)"
        }
        return type.rawValue
    }
}

struct HomeTagRowData: Identifiable, Sendable {
    let type: HomeRowType
    let tags: [TagCardData]

    var id: String { type.rawValue }
}
