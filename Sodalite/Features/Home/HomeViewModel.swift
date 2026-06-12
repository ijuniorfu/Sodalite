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
    /// nothing the user can perceive. Internal (not private) so the
    /// +Precompute extension can read and latch it.
    var providerCountsComputedAt: Date?

    /// Same throttle as `providerCountsComputedAt`, but for the
    /// genre-tile pre-warm pass. The grids themselves still revalidate
    /// against the server when opened, this just means the *first*
    /// frame after a tap is already painted from the file cache.
    var genreCachesComputedAt: Date?

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

    // Internal (not private) so the +Rows / +Precompute extensions
    // can reach the services + identity the moved fetch logic uses.
    let libraryService: JellyfinLibraryServiceProtocol
    let imageService: JellyfinImageService
    let discoverService: SeerrDiscoverServiceProtocol?
    let userID: String
    let serverID: String
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

    isolated deinit {
        // The background fan-outs hold self weakly so they can't keep
        // a discarded VM alive, but a task still in its deferred-sleep
        // phase would otherwise linger for up to 13 s after the VM is
        // gone (profile switch tears the VM down via HomeView). A pass
        // that is mid-query holds self strongly for its duration; the
        // cancel also flips Task.isCancelled so its next checkpoint
        // stops the work early.
        backdropTask?.cancel()
        providerCountsTask?.cancel()
        genreCachesTask?.cancel()
    }

    func loadContent() async {
        loadGeneration += 1
        let myGen = loadGeneration

        // Cancel the previous run's background fan-outs up front, NOT
        // just before scheduling new ones: the total-failure return
        // below used to skip the late cancel block, leaving the old
        // tasks fetching and writing FilterCache for a config this
        // reload was about to replace.
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
            // Merged-row mode: Next Up rides inside Continue Watching
            // (see loadRow), so its standalone row drops out even
            // while its config stays enabled, flipping the toggle
            // back restores it without re-enabling anything.
            if config.type == .nextUp,
               HomeRowConfig.mergeContinueWatchingNextUp(serverID: serverID) {
                return nil
            }
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

    func imageURL(
        for item: JellyfinItem,
        rowType: HomeRowType,
        cwImage: AppearancePreferences.ContinueWatchingImage = .still
    ) -> URL? {
        guard rowType.usesBackdrop else {
            return imageService.posterURL(for: item)
        }
        // Continue Watching / Up Next image, per the user's choice.
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
            // Series Thumb addressed by series id (tagless). Paired with
            // fallbackImageURL so a Thumb-less show degrades gracefully.
            let id = (item.type == .episode ? item.seriesId : nil) ?? item.id
            return imageService.imageURL(itemID: id, imageType: .thumb, maxWidth: 720)
        }
    }

    /// Fallback image for Continue Watching / Up Next, used under the
    /// Thumb option so a show without a Thumb degrades to its backdrop or
    /// the episode still. Nil for the other options (their primary URL
    /// already chains to a present image).
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