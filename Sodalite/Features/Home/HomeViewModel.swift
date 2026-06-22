import SwiftUI

@Observable
final class HomeViewModel {
    var rows: [HomeRowData] = []
    var tagRows: [HomeTagRowData] = []
    var isLoading = true
    var errorMessage: String?
    var rowConfigs: [HomeRowConfig] = []
    var needsReload = false
    /// Sample backdrop per provider TMDB id from a one-shot Studios query so each provider tile shows a real library hero; nil falls back to logo-only.
    var providerBackdrops: [Int: URL] = [:]

    /// Resolved-item count per provider id from the background precompute; the home view's empty-tile-hide filter reads it to drop zero-match providers without the user tapping each one.
    var providerItemCounts: [Int: Int] = [:]

    /// Throttle against repeated precompute runs per session (re-resolving every provider on each Home re-appearance is ~100 Seerr calls for no perceptible gain). Internal so +Precompute can latch it.
    var providerCountsComputedAt: Date?

    /// Same throttle for the genre-tile pre-warm; grids still revalidate on open, this just paints the first post-tap frame from the file cache.
    var genreCachesComputedAt: Date?

    /// Handles for loadContent's background fan-outs, cancelled on teardown or re-entry, else an orphaned VM keeps fetching and writing FilterCache after its UI is gone.
    private var backdropTask: Task<Void, Never>?
    private var providerCountsTask: Task<Void, Never>?
    private var genreCachesTask: Task<Void, Never>?

    /// Last successful loadContent(); the view's onAppear uses it to decide whether to refresh, else new server-side content never shows until app restart.
    var lastLoadedAt: Date?

    /// Bumped on every loadContent entry; the for-await loop checks it before publishing so a re-entrant run (profile switch, refresh-while-loading) supersedes the older one instead of both writing rows/tagRows.
    private var loadGeneration: Int = 0

    // Internal (not private) so +Rows / +Precompute can reach the services + identity.
    let libraryService: JellyfinLibraryServiceProtocol
    let imageService: JellyfinImageService
    let discoverService: SeerrDiscoverServiceProtocol?
    let userID: String
    let serverID: String
    /// Video libraries (movies/tvshows/homevideos/mixed) for the My Media row; populated by loadContent().
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

    isolated deinit {
        // Fan-outs hold self weakly, but a deferred-sleep task would linger up to 13 s after the VM is gone (profile switch); cancel flips Task.isCancelled so the next checkpoint stops early.
        backdropTask?.cancel()
        providerCountsTask?.cancel()
        genreCachesTask?.cancel()
    }

    /// Patch a just-watched item's resume progress in place across every row holding it (issue #24). Mirrors the detail-side fix off the authoritative playback-stop payload so the Continue Watching progress bar is right immediately without racing a loadContent() re-fetch. loadContent() still runs for structural changes a patch can't make (re-ordering, dropping out once finished).
    @MainActor
    func applyPlaybackPosition(itemID: String, ticks: Int64) {
        for rowIndex in rows.indices {
            for itemIndex in rows[rowIndex].items.indices
            where rows[rowIndex].items[itemIndex].id == itemID {
                rows[rowIndex].items[itemIndex].setResumePosition(ticks)
            }
        }
    }

    func loadContent() async {
        loadGeneration += 1
        let myGen = loadGeneration

        // Cancel previous fan-outs up front, not before scheduling new ones: the total-failure return below used to skip a late cancel, leaving old tasks fetching/writing FilterCache for a config being replaced.
        backdropTask?.cancel()
        providerCountsTask?.cancel()
        genreCachesTask?.cancel()
        backdropTask = nil
        providerCountsTask = nil
        genreCachesTask = nil

        let isFirstLoad = rows.isEmpty && tagRows.isEmpty
        if isFirstLoad {
            isLoading = true
        }
        errorMessage = nil

        // Pull the server's libraries for per-library Latest + My Media. Reconciliation is additive (keeps user toggles/order); persist only on success so a transient failure can't wipe the dynamic rows.
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

        // Fan out every row's call in parallel (a sequential for-await made a 7-row config take ~7× the slowest call). orderedSections() drives display order from sortOrder, so arrival order only affects paint timing.
        enum RowResult: Sendable {
            case media(HomeRowData)
            case tag(HomeTagRowData)
            case empty
        }

        // Precompute isTagRow + carry the full config on MainActor: HomeRowType is MainActor-isolated under default-isolation, so the task-group closures can't read .isTagRow themselves; the full config keeps per-library libraryID/name and unique identity.
        let plan: [(config: HomeRowConfig, isTag: Bool)] = enabledRows.compactMap { config in
            if config.type.isDiscoverProviderRow { return nil }
            // My Media renders from videoLibraries directly; nothing to fetch.
            if config.type == .myMedia { return nil }
            // Merged mode: Next Up rides inside Continue Watching (see loadRow), so its standalone row drops out while its config stays enabled; flipping the toggle restores it.
            if config.type == .nextUp,
               HomeRowConfig.mergeContinueWatchingNextUp(serverID: serverID) {
                return nil
            }
            return (config, config.type.isTagRow)
        }

        let plannedMediaIDs = Set(plan.filter { !$0.isTag }.map(\.config.id))
        let plannedTagIDs = Set(plan.filter { $0.isTag }.map(\.config.id))

        // Drop rows disabled since the previous load instantly; still-enabled rows stay and get replaced in place as fresh results land.
        rows.removeAll { !plannedMediaIDs.contains($0.id) }
        tagRows.removeAll { !plannedTagIDs.contains($0.id) }

        var sawAnyResult = false

        // Progressive publish: upsert each row as it completes so fast rows paint while the slowest (Latest on a huge library, 10+ s) streams. ForEach diffs by HomeRowData.id, so in-place replace preserves mounted AsyncImage state.
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
                // Stale guard: a newer loadContent superseded this; drop the rest so we don't fight it for the rows array.
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

        // Total-failure path: loadRow/loadTagRow swallow errors and return nil, so "all nils" looks like "server unreachable". Surface the retry overlay only on first load; on refresh keep on-screen rows so a transient CDN hiccup doesn't wipe Home.
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

        // Gate each background pass on its consuming row being enabled: the provider precompute is the heaviest query (one 10 000-item all-library scan + 33 per-provider resolves) and only the Discover row reads it, so hiding that row in Customize genuinely stops the scan (Sodalite#12 backend contention), not just the tiles.
        let providersEnabled = enabledRows.contains { $0.type.isDiscoverProviderRow }
        let genresEnabled = enabledRows.contains { $0.type == .genres }

        // All three deferred + .utility so secondary queries don't compete with the user's first detail navigation; staggered (3s/8s/13s) so the two heaviest don't land on the HTTPClient limiter at once and starve each other on a slow CDN (Sodalite#12).

        // One Studios query per provider for a sample backdrop; gaps tolerated (tile falls back to logo-only).
        if providersEnabled {
            backdropTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await self?.loadProviderBackdrops()
            }
        }
        // Pre-resolve provider tiles so the empty-tile-hide pass has data before the user taps each one. One run per session, heaviest of the three (10 000-item query + per-provider studio/TMDB matches), deferred longest.
        if providersEnabled {
            providerCountsTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { return }
                await self?.precomputeProviderCounts()
            }
        }
        // Pre-warm genre grids so the first tap renders from cache.
        if genresEnabled {
            genreCachesTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(13))
                if Task.isCancelled { return }
                await self?.precomputeGenreCaches()
            }
        }
    }

    func imageURL(
        for item: JellyfinItem,
        rowType: HomeRowType,
        cwImage: AppearancePreferences.ContinueWatchingImage = .still
    ) -> URL? {
        guard rowType.usesBackdrop else {
            return imageService.posterURL(for: item)
        }
        switch cwImage {
        case .still:
            if item.type == .episode {
                return imageService.episodeThumbnailURL(for: item)
            }
            return imageService.backdropURL(for: item) ?? imageService.posterURL(for: item)
        case .backdrop:
            return imageService.backdropURL(for: item)
                ?? imageService.episodeThumbnailURL(for: item)
                ?? imageService.posterURL(for: item)
        case .thumb:
            // Series Thumb by series id (tagless); paired with fallbackImageURL so a Thumb-less show degrades.
            let id = (item.type == .episode ? item.seriesId : nil) ?? item.id
            return imageService.imageURL(itemID: id, imageType: .thumb, maxWidth: 720)
        }
    }

    /// Fallback under the Thumb option so a Thumb-less show degrades to backdrop/still. Nil for the other options (their primary URL already chains).
    func fallbackImageURL(
        for item: JellyfinItem,
        cwImage: AppearancePreferences.ContinueWatchingImage
    ) -> URL? {
        guard cwImage == .thumb else { return nil }
        return imageService.backdropURL(for: item)
            ?? imageService.episodeThumbnailURL(for: item)
            ?? imageService.posterURL(for: item)
    }

    func reloadConfig() {
        rowConfigs = HomeRowConfig.loadFromStorage(serverID: serverID)
    }

    /// On active-server change: clear in-memory carousels (so the old server's posters don't linger) and reset the throttle guards so precompute reruns for the new library, then reload.
    @MainActor
    func reloadAfterServerSwitch() async {
        // Flip to loading before clearing rows so HomeView lands in the spinner branch, not the empty no-content branch.
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