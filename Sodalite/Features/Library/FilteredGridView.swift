import SwiftUI

/// Watch-status narrowing for the library grids (Sodalite#17,
/// requested by RyoShinzo). Maps to Jellyfin's `Filters` parameter;
/// `.all` sends nothing and is the long-standing default.
enum WatchStatusFilter: String, CaseIterable, Hashable {
    case all
    case unwatched
    case watched

    /// Jellyfin `Filters` value, nil for the unfiltered default.
    var jellyfinFilter: String? {
        switch self {
        case .all: nil
        case .unwatched: "IsUnplayed"
        case .watched: "IsPlayed"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .all: "library.filter.all"
        case .unwatched: "library.filter.unwatched"
        case .watched: "library.filter.watched"
        }
    }
}

struct FilteredGridView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var items: [JellyfinItem]
    @State private var isLoading: Bool
    @State private var selectedItem: JellyfinItem?
    @State private var watchFilter: WatchStatusFilter = .all
    @FocusState private var focusedItemID: String?
    @Environment(\.dismiss) private var dismiss

    /// Distinguishes "fetch failed with nothing to show" (error state
    /// with a retry) from "server says the list is empty".
    @State private var loadFailed = false
    /// Stamped at the start of every loadItems run; checked after each
    /// await so a superseded run (filter flip, retry) can never write
    /// its results over the newer run's.
    @State private var loadGeneration = 0
    /// TotalRecordCount from the last phase-1 response; drives the
    /// load-more trigger. nil until the first fresh fetch lands.
    @State private var totalRecordCount: Int?
    @State private var isLoadingMore = false
    /// True once loadMore has appended at least one page this filter
    /// cycle. The refresh pass uses it to keep the appended pages
    /// instead of truncating the grid back to page 1 under the user's
    /// focus. Explicit flag, not a count/prefix heuristic: a server-
    /// side reorder of page 1 (new item added at the front) breaks
    /// prefix comparison even though the user genuinely paginated.
    @State private var didPaginate = false

    let title: String
    let query: ItemQuery
    /// Optional TMDB watch-provider id. When set, after the studio
    /// filter resolves we ask Jellyseerr for the live "currently
    /// streaming on this service" list and look up any matches in
    /// the local library. Lets shows like Modern Family or Bluey
    /// surface under Disney+ even though their Studios tag points at
    /// 20th Century Fox Television / Ludo Studio respectively.
    let smartProviderID: Int?
    let smartProviderRegion: String?
    /// Stable identifier used by FilterCache to persist the final
    /// merged item list. Independent of `smartProviderID` so even
    /// providers without a watch-provider concept (broadcast nets
    /// like ABC / NBC / CBS) still get their result cached, and
    /// therefore become eligible for the empty-tile-hide pass on
    /// the next visit.
    let cacheKey: String?

    init(
        title: String,
        query: ItemQuery,
        smartProviderID: Int? = nil,
        smartProviderRegion: String? = nil,
        cacheKey: String? = nil
    ) {
        self.title = title
        self.query = query
        self.smartProviderID = smartProviderID
        self.smartProviderRegion = smartProviderRegion
        self.cacheKey = cacheKey
        // Hydrate from FilterCache during init so the very first
        // body render already paints the cached grid. Doing it
        // inside `.task` later means one frame with isLoading=true
        // before the cache snaps in, that's the brief "loading
        // flash" the user perceives on every tap.
        if let key = cacheKey,
           let cached = FilterCache.shared.homeFilterItems(filterKey: key),
           !cached.isEmpty {
            _items = State(initialValue: cached)
            _isLoading = State(initialValue: false)
        } else {
            _items = State(initialValue: [])
            _isLoading = State(initialValue: true)
        }
    }

    var body: some View {
        ScrollView {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 60)
                .padding(.top, 20)

            // Watch-status filter (Sodalite#17). Native segmented
            // control per the app's section-picker convention
            // (Catalog tabs, Live TV Guide/Recordings).
            Picker("", selection: $watchFilter) {
                ForEach(WatchStatusFilter.allCases, id: \.self) { filter in
                    Text(filter.localizedTitle).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 60)
            .padding(.top, 8)

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    // Focusable element so Menu button works during loading
                    Button("") { dismiss() }
                        .opacity(0)
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            } else if items.isEmpty, loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("home.error.unreachable")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                    Button {
                        isLoading = true
                        loadFailed = false
                        Task { await loadItems() }
                    } label: {
                        Text("home.retry")
                            .font(.body)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(SettingsTileButtonStyle())
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("library.empty.message")
                        .foregroundStyle(.secondary)
                    Button { dismiss() } label: {
                        Text("common.back")
                            .font(.body)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(SettingsTileButtonStyle())
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 220), spacing: 40)
                ], spacing: 50) {
                    ForEach(items) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            MediaCard(
                                item: item,
                                imageURL: dependencies.jellyfinImageService.posterURL(for: item),
                                isFocused: focusedItemID == item.id
                            )
                        }
                        .buttonStyle(GridCardButtonStyle())
                        .focused($focusedItemID, equals: item.id)
                        .onAppear { loadMoreIfNeeded(after: item) }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)

                if isLoadingMore {
                    ProgressView()
                        .padding(.bottom, 40)
                }
            }
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $selectedItem) { item in
            DetailRouterView(item: item)
        }
        .onChange(of: watchFilter) { _, _ in
            // Filter switch: drop the now-mismatched grid immediately
            // (stale-while-revalidate would briefly show watched items
            // under "Unwatched") and let the keyed task below refetch.
            items = []
            isLoading = true
            loadFailed = false
            totalRecordCount = nil
            didPaginate = false
        }
        .task(id: watchFilter) {
            await loadItems()
            // Nudge focus to the first item only on the very first
            // appearance, if the user has already navigated by the
            // time loadItems returns (cache hit + Phase 2 augment
            // can take a couple of seconds during which they're
            // free to scroll), forcing focus back to position 0
            // would yank them out of where they are.
            guard focusedItemID == nil, let firstID = items.first?.id else { return }
            deferOnMain(by: 0.1) {
                // Recheck at fire time, the user could have moved
                // focus during the 100 ms gap.
                if focusedItemID == nil {
                    focusedItemID = firstID
                }
            }
        }
    }

    /// Phase-1 (studio match) results, kept separate from `items` so
    /// the augmentation refresh can rebuild the merged grid without
    /// re-running the studio query.
    @State private var studioItems: [JellyfinItem] = []

    private func loadItems() async {
        guard let userID = appState.activeUser?.id else { return }
        loadGeneration += 1
        let generation = loadGeneration

        // Cache hydration happened in init(...), items + isLoading
        // already reflect the cache hit (or miss). Now run the
        // background refresh that replaces them with the freshest
        // server response.

        // Watch-status filter applies server-side to BOTH phases:
        // phase 1 directly, and the full-library map the smart
        // provider augment resolves against, so phase 2 cannot
        // re-introduce filtered-out items. `.all` sends nothing.
        var effectiveQuery = query
        if let filter = watchFilter.jellyfinFilter {
            effectiveQuery.filters = [filter]
        }
        let isWatchFiltered = watchFilter != .all

        // nil = fetch failed or was cancelled. The distinction from
        // "server says empty" matters: a failure must never replace
        // the on-screen grid or be persisted into FilterCache as a
        // valid empty result (that used to poison the cache and kill
        // the instant-paint hydration until the next pre-warm).
        async let studioMatchTask: JellyfinItemsResponse? = { [effectiveQuery] in
            try? await dependencies.jellyfinLibraryService.getItems(
                userID: userID, query: effectiveQuery
            )
        }()

        async let allLibraryTask: [JellyfinItem]? = { [watchFilterValue = watchFilter.jellyfinFilter] in
            guard smartProviderID != nil else { return [] }
            // Fetch the entire library in one shot rather than running
            // per-id `AnyProviderIdEquals` lookups. Robust against
            // Jellyfin version quirks and amortises across every
            // TMDB id we want to resolve.
            var allQuery = ItemQuery(
                includeItemTypes: [.movie, .series],
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: 10000
            )
            if let filter = watchFilterValue {
                allQuery.filters = [filter]
            }
            return try? await dependencies.jellyfinLibraryService.getItems(
                userID: userID, query: allQuery
            ).items
        }()

        let phase1Response = await studioMatchTask
        let allItems = await allLibraryTask

        // Backed out (Menu press, tap into a detail page) or superseded
        // by a newer run: leave every piece of state alone.
        guard !Task.isCancelled, generation == loadGeneration else { return }

        guard let phase1Response else {
            // Real failure. Keep whatever the cache hydrated; only
            // surface the error state when there is nothing to show.
            loadFailed = items.isEmpty
            isLoading = false
            return
        }
        loadFailed = false
        let phase1 = phase1Response.items
        studioItems = phase1
        totalRecordCount = phase1Response.totalRecordCount

        // Build TMDB-id → JellyfinItem map once and reuse for the
        // background refresh.
        var tmdbMap: [Int: JellyfinItem] = [:]
        for item in allItems ?? [] {
            if let id = item.tmdbID { tmdbMap[id] = item }
        }

        // No cache yet → at least surface the studio match while the
        // watch-provider phase runs.
        if items.isEmpty {
            items = phase1
            isLoading = false
        }

        // Always refresh, the cache is stale-while-revalidate. The
        // fresh list replaces whatever the cache held, so titles that
        // rotated off the service since last visit drop out.
        if let providerID = smartProviderID, let region = smartProviderRegion {
            // The 10k library scan feeding tmdbMap failed: the augment
            // would resolve against an empty map and shrink the grid /
            // cache to studio-only matches. Skip the refresh round.
            guard allItems != nil else {
                isLoading = false
                return
            }
            await refreshWatchProviderAugment(
                providerID: providerID,
                region: region,
                tmdbMap: tmdbMap,
                generation: generation,
                isWatchFiltered: isWatchFiltered
            )
        } else {
            // No smart filter (broadcast networks, generic genre /
            // studio tiles), Phase 1 is the final result. Persist
            // it so the empty-tile-hide pass on the next visit has
            // a count to work with, and so a re-tap renders without
            // the studio-query roundtrip. Skip the assignment when
            // the id list is unchanged: even with identical ids the
            // wholesale replace forces SwiftUI to re-diff every cell,
            // which reads to the user as a brief reload flash. And
            // when the user already paginated past page 1, keep the
            // appended pages instead of truncating the grid under
            // their focus (explicit didPaginate flag; the old
            // count/prefix heuristic broke when the server reordered
            // page 1, truncating a paginated grid).
            let pagedPastPhase1 = didPaginate && !items.isEmpty
            if !pagedPastPhase1, items.map(\.id) != phase1.map(\.id) {
                items = phase1
            }
            isLoading = false
            // Cache only the unfiltered default: the cached list feeds
            // init hydration (always .all) and the empty-tile-hide
            // counts, both of which must reflect the full library.
            if let key = cacheKey, !isWatchFiltered {
                FilterCache.shared.setHomeFilterItems(phase1, filterKey: key)
            }
        }
    }

    // MARK: - Pagination

    /// Whether more pages exist server-side. Only the plain (non-smart)
    /// path paginates: smart-provider grids are merged from the full
    /// library map and complete by construction, and genre/My-Media
    /// tiles were previously hard-truncated at their query limit with
    /// no indication anything was missing.
    private var canLoadMore: Bool {
        guard smartProviderID == nil, query.limit != nil else { return false }
        guard let total = totalRecordCount else { return false }
        return items.count < total
    }

    private func loadMoreIfNeeded(after item: JellyfinItem) {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        // Trigger within the last two grid rows so the next page is
        // in place before focus reaches the edge.
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 12 else { return }
        isLoadingMore = true
        Task { await loadMore() }
    }

    private func loadMore() async {
        defer { isLoadingMore = false }
        guard let userID = appState.activeUser?.id else { return }
        let generation = loadGeneration

        var pageQuery = query
        if let filter = watchFilter.jellyfinFilter {
            pageQuery.filters = [filter]
        }
        pageQuery.startIndex = items.count

        guard let response = try? await dependencies.jellyfinLibraryService.getItems(
            userID: userID, query: pageQuery
        ) else { return }
        guard !Task.isCancelled, generation == loadGeneration else { return }

        totalRecordCount = response.totalRecordCount
        let known = Set(items.map(\.id))
        items += response.items.filter { !known.contains($0.id) }
        didPaginate = true
    }

    /// Background refresh of the TMDB watch-provider id list: 5
    /// pages each on movies + tv, then re-resolve against the local
    /// library map and write the fresh ids to the cache. Shows the
    /// updated grid the moment the new list lands. Stale entries
    /// drop out automatically because the merged grid is rebuilt
    /// from scratch every refresh.
    private func refreshWatchProviderAugment(
        providerID: Int,
        region: String,
        tmdbMap: [Int: JellyfinItem],
        generation: Int,
        isWatchFiltered: Bool
    ) async {
        let providerTmdbIDs = await dependencies.seerrDiscoverService
            .collectWatchProviderTmdbIDs(providerID: providerID, region: region)

        guard !Task.isCancelled, generation == loadGeneration else { return }

        // collectWatchProviderTmdbIDs swallows failures into an empty
        // set, so emptiness is ambiguous: a transient Seerr outage is
        // indistinguishable from "this service streams nothing". A
        // real streaming service never has zero titles, treat empty
        // as a failed round: keep the on-screen grid and the cached
        // entry, surface phase 1 only if nothing is showing yet.
        guard !providerTmdbIDs.isEmpty else {
            if items.isEmpty {
                items = studioItems
            }
            isLoading = false
            return
        }

        FilterCache.shared.setSmartFilterIDs(
            Array(providerTmdbIDs), providerID: providerID, region: region
        )

        let phase2Items = providerTmdbIDs.compactMap { tmdbMap[$0] }
        let merged = ProviderMatchMerging.merge(phase1: studioItems, phase2: phase2Items)
        if items.map(\.id) != merged.map(\.id) {
            items = merged
        }
        isLoading = false

        // Persist the fully-resolved list so the next visit can
        // hydrate the grid synchronously, no library fetch, no
        // watch-provider roundtrip needed for the initial display.
        // Unfiltered default only, same rationale as the phase-1 write.
        if let key = cacheKey, !isWatchFiltered {
            FilterCache.shared.setHomeFilterItems(merged, filterKey: key)
        }
    }
}

struct GridCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Stroke is drawn inside MediaCard (around the poster only),
        // keeping the title text below the card outside the outline.
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
