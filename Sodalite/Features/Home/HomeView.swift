import SwiftUI

struct HomeView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel: HomeViewModel?
    @State private var selectedItem: JellyfinItem?
    @State private var selectedFilter: FilterDestination?

    /// Tracks which content row currently holds focus. Goes `nil`
    /// when focus moves out of the rows (typically: user pressed Up
    /// at the top row and the focus engine jumped to the tab bar).
    /// Used to drive an auto-scroll-to-top so the tab bar is fully
    /// visible (not clipped by scrolled-down content) when the user
    /// arrives at it from below.
    @FocusState private var focusedRowIndex: Int?

    /// Debounce task for the focus-left-rows → scroll-to-top action.
    /// Cancelled and respawned every time `focusedRowIndex` changes.
    /// Without this debounce, transient nil states between row
    /// transitions (the focus engine briefly has no focused descendant
    /// during fast up / down navigation) trigger spurious scroll-to-top
    /// snaps that fight with the user's scroll direction.
    @State private var scrollResetTask: Task<Void, Never>?

    /// serverDidSwitch value of the last switch this view reacted to.
    /// `.task(id:)` re-fires with the SAME id every time the view
    /// reappears (tab change, sheet dismiss); without the latch each
    /// reappear would wipe FilterCache and reload the whole feed even
    /// though no switch happened.
    @State private var lastHandledServerSwitch = 0

    /// How long the home feed is considered fresh before a revisit
    /// triggers an automatic reload.
    private static let refreshStaleSeconds: TimeInterval = 60

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    if vm.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = vm.errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text(error)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await vm.loadContent() }
                            } label: {
                                Text("home.retry")
                                    .font(.body)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(SettingsTileButtonStyle())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        contentView(vm: vm)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(item: $selectedItem) { item in
                DetailRouterView(item: item)
            }
            .navigationDestination(item: $selectedFilter) { filter in
                FilteredGridView(
                    title: filter.title,
                    query: filter.query,
                    smartProviderID: filter.smartProviderID,
                    smartProviderRegion: filter.smartProviderRegion,
                    cacheKey: filter.cacheKey
                )
            }
        }
        .onAppear {
            guard let userID = appState.activeUser?.id else { return }
            if viewModel == nil {
                viewModel = HomeViewModel(
                    libraryService: dependencies.jellyfinLibraryService,
                    imageService: dependencies.jellyfinImageService,
                    discoverService: dependencies.seerrDiscoverService,
                    userID: userID,
                    serverID: appState.activeServer?.id ?? userID
                )
                Task { await viewModel?.loadContent() }
            } else if viewModel?.needsReload == true {
                viewModel?.needsReload = false
                Task { await viewModel?.loadContent() }
            } else if let last = viewModel?.lastLoadedAt,
                      Date().timeIntervalSince(last) > Self.refreshStaleSeconds {
                // Pick up new server-side content (Latest Movies,
                // Latest Series, …) when the user comes back to Home
                // after a while. 60 s is tight enough that fresh
                // additions show up quickly and loose enough that
                // rapid tab-hopping doesn't spam the server.
                Task { await viewModel?.loadContent() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeConfigDidChange)) { _ in
            viewModel?.reloadConfig()
            viewModel?.needsReload = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeFavoritesDidChange)) { _ in
            Task { await viewModel?.loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homePlayedDidChange)) { _ in
            Task { await viewModel?.loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidChange)) { _ in
            // The Jellyfin server has fresh progress for whatever
            // the user just watched. Reload so Continue Watching and
            // Next Up reflect it as soon as the user is back here.
            Task { await viewModel?.loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeItemDidDelete)) { _ in
            // The user just deleted an item. Reload so it drops out of
            // the rows immediately instead of lingering until the next
            // stale refresh.
            Task { await viewModel?.loadContent() }
        }
        .onChange(of: appState.activeUser?.id) { _, newValue in
            // Profile switch, tear down the old HomeViewModel so the
            // next .onAppear rebuilds it with the new userID. Leaving
            // the old one around would keep loading content for the
            // previous profile's permissions + watch state.
            guard let userID = newValue else {
                viewModel = nil
                return
            }
            viewModel = HomeViewModel(
                libraryService: dependencies.jellyfinLibraryService,
                imageService: dependencies.jellyfinImageService,
                discoverService: dependencies.seerrDiscoverService,
                userID: userID,
                serverID: appState.activeServer?.id ?? userID
            )
            Task { await viewModel?.loadContent() }
        }
        .task(id: appState.serverDidSwitch) {
            // Value 0 is the initial state; no switch has occurred yet.
            let signal = appState.serverDidSwitch
            guard signal > 0, signal != lastHandledServerSwitch else { return }
            lastHandledServerSwitch = signal
            // Roll the latch back if this run is cancelled mid-reload
            // (view disappears) so the re-fire on reappear finishes
            // the job instead of being guarded away.
            defer {
                if Task.isCancelled, lastHandledServerSwitch == signal {
                    lastHandledServerSwitch = 0
                }
            }
            FilterCache.shared.clearAll()
            await viewModel?.reloadAfterServerSwitch()
        }
    }

    private func contentView(vm: HomeViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Invisible top anchor for programmatic scroll-to-top
                // when focus leaves the rows (user arrives at the
                // tab bar from below). Zero-height + `Color.clear`
                // so it doesn't affect layout.
                Color.clear.frame(height: 0).id("top")
                LazyVStack(alignment: .leading, spacing: 40) {
                    ForEach(Array(vm.orderedSections().enumerated()), id: \.element.id) { idx, section in
                    switch section {
                    case .media(let row):
                        let cwImage = row.type.usesBackdrop
                            ? dependencies.appearancePreferences.continueWatchingImage
                            : .still
                        HorizontalMediaRow(
                            title: row.type.localizedTitle,
                            verbatimTitle: row.type == .libraryLatest
                                ? String(
                                    format: String(
                                        localized: "home.libraryLatest.format",
                                        defaultValue: "Latest in %@"
                                    ),
                                    row.libraryName ?? ""
                                )
                                : nil,
                            items: row.items,
                            imageURLProvider: { vm.imageURL(for: $0, rowType: row.type, cwImage: cwImage) },
                            fallbackURLProvider: cwImage == .thumb
                                ? { vm.fallbackImageURL(for: $0, cwImage: cwImage) }
                                : nil,
                            onItemSelected: { selectedItem = $0 },
                            cardStyle: row.type.cardStyle
                        )
                        .focused($focusedRowIndex, equals: idx)

                    case .tags(let tagRow):
                        TagRow(
                            title: tagRow.type.localizedTitle,
                            tags: tagRow.tags,
                            onTagSelected: { tagData in
                                selectedFilter = makeFilter(for: tagData, type: tagRow.type)
                            }
                        )
                        .focused($focusedRowIndex, equals: idx)

                    case .discoverProviders:
                        // Hide tiles whose resolved match count is
                        // zero. The view-model precomputes counts in
                        // the background (so the filter activates
                        // automatically without requiring the user
                        // to tap each tile first); a `nil` count
                        // means "not yet computed" and shows the
                        // tile, so first-run sees everything until
                        // the precompute fills in the dict and empty
                        // tiles fade out a few seconds later. Once
                        // the user adds matching content the tile
                        // re-appears on the next session, the
                        // precompute reruns and the count climbs
                        // above zero.
                        let visibleProviders = CatalogProviders.networks.filter { provider in
                            let count = vm.providerItemCounts[provider.id]
                            return count == nil || count! > 0
                        }
                        if !visibleProviders.isEmpty {
                            CatalogProviderRow(
                                titleKey: HomeRowType.discoverProviders.localizedTitle,
                                providers: visibleProviders,
                                onSelect: { provider in
                                    selectedFilter = makeJellyfinFilter(for: provider)
                                },
                                backdropFor: { provider in
                                    vm.providerBackdrops[provider.id]
                                }
                            )
                            .focused($focusedRowIndex, equals: idx)
                        }

                    case .libraries(let libraries):
                        LibraryRow(
                            titleKey: HomeRowType.myMedia.localizedTitle,
                            libraries: libraries,
                            onSelect: { library in
                                selectedFilter = makeLibraryFilter(for: library)
                            }
                        )
                        .focused($focusedRowIndex, equals: idx)
                    }
                }
                }
                .padding(.vertical, 40)
            }
            .onChange(of: focusedRowIndex) { oldValue, newValue in
                // Scroll content to top only when focus left specifically
                // the topmost row (oldValue == 0) and stayed away long
                // enough to be a real tab-bar arrival (not a transient
                // nil between row materializations).
                //
                // Two constraints, both needed:
                //
                // 1. `oldValue == 0`: the focus engine only routes Up
                //    from the topmost row to the tab bar. Up from row N
                //    (N > 0) goes to row N-1, not to the tab bar. If
                //    focusedRowIndex transitions row-N → nil while
                //    N > 0, the nil is a transient between row
                //    materializations (LazyVStack lays out the next
                //    row), NOT an actual tab-bar arrival. Filtering on
                //    oldValue == 0 eliminates those false triggers
                //    during normal down-scrolling.
                //
                // 2. 200 ms debounce via cancellable Task: even for
                //    a legitimate row-0 → tab-bar transition, the focus
                //    engine briefly has no focused descendant. If the
                //    user is scrolling DOWN from row 0 to row 1, the
                //    state may also pass through nil for a beat. The
                //    debounce gives the focus engine time to settle on
                //    the next row before we commit to scroll-to-top.
                //    200 ms is comfortably longer than any inter-row
                //    transient observed and still feels immediate when
                //    the user actually parks focus on the tab bar.
                scrollResetTask?.cancel()
                guard newValue == nil, oldValue == 0 else { return }
                scrollResetTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
        }
    }

    private func makeJellyfinFilter(for provider: CatalogProvider) -> FilterDestination {
        // Tap on a Netflix/Disney+/… tile filters the *local* library
        // by Studio rather than pushing the Jellyseerr discover page.
        // Multiple aliases are pipe-joined in JellyfinEndpoints, so a
        // user whose scraper tagged some items "Disney+" and others
        // "Walt Disney Pictures" gets both in one row. The smart-
        // provider hint augments that with TMDB's live watch-provider
        // data so titles whose Studios tag doesn't betray the streamer
        // still surface (Modern Family on Disney+, Bluey via Ludo
        // Studio, …).
        let region = Locale.current.region?.identifier ?? "US"
        return FilterDestination(
            title: provider.name,
            query: ItemQuery(
                includeItemTypes: [.movie, .series],
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: 200,
                studioNames: provider.jellyfinStudioNames
            ),
            smartProviderID: provider.tmdbWatchProviderID,
            smartProviderRegion: region,
            cacheKey: HomeView.providerCacheKey(provider: provider, region: region)
        )
    }

    /// Convenience that pulls the right key out of the central
    /// `FilterCacheKey.Home` namespace, kept here so existing call
    /// sites that pass a `CatalogProvider` don't have to reach into
    /// the provider's id field themselves.
    static func providerCacheKey(provider: CatalogProvider, region: String) -> String {
        FilterCacheKey.Home.provider(id: provider.id, region: region)
    }

    private func makeFilter(for tag: TagCardData, type: HomeRowType) -> FilterDestination {
        switch type {
        case .genres:
            FilterDestination(
                title: tag.name,
                query: ItemQuery(
                    includeItemTypes: [.movie, .series],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 50,
                    genres: [tag.name]
                ),
                // Without a cacheKey FilteredGridView's init() falls
                // through to the empty-state branch and shows
                // isLoading=true on every visit, that's the "lädt
                // kurz" the user perceives every time they open a
                // genre tile. Tag name is the differentiator (Action,
                // Comedy, Drama, …) so it's a stable enough key.
                cacheKey: FilterCacheKey.Home.genre(name: tag.name)
            )
        default:
            FilterDestination(
                title: tag.name,
                query: ItemQuery(),
                cacheKey: FilterCacheKey.Home.tag(name: tag.name)
            )
        }
    }

    private func makeLibraryFilter(for library: JellyfinLibrary) -> FilterDestination {
        // Tap a My Media tile -> browse that one library in the shared
        // filtered grid. parentID scopes the query to the library; the
        // item types match what the library holds.
        let types: [ItemType]
        switch library.libraryType {
        case .movies: types = [.movie]
        case .tvshows: types = [.series]
        default: types = [.movie, .series]
        }
        return FilterDestination(
            title: library.name,
            query: ItemQuery(
                parentID: library.id,
                includeItemTypes: types,
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: 200
            ),
            cacheKey: "library_\(library.id)"
        )
    }
}

struct FilterDestination: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let query: ItemQuery
    /// Optional TMDB watch-provider id used to augment the studio-
    /// name filter with the live "what's actually streaming on this
    /// service right now" list from Jellyseerr, picks up titles
    /// whose Studios tag in Jellyfin doesn't betray the streamer
    /// (Modern Family on Disney+, Bluey via Ludo Studio, Suits on
    /// Netflix even though the studio is Universal, …). nil → only
    /// the studio match runs.
    var smartProviderID: Int?
    /// ISO 3166-1 alpha-2 region used with `smartProviderID`. TMDB's
    /// watch-provider data is region-specific (Disney+ in DE has
    /// different titles than Disney+ in US), so we always pin to a
    /// concrete region, defaulting to the user's `Locale.current`.
    var smartProviderRegion: String?
    /// Stable identifier under which FilteredGridView caches its
    /// final result. Set independently of `smartProviderID` so that
    /// broadcast-only tiles (ABC / NBC / CBS, no watch-provider
    /// concept) still cache their results and feed the empty-tile-
    /// hide pass on the next visit.
    var cacheKey: String?
}

extension ItemQuery: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(parentID)
        hasher.combine(sortBy)
        hasher.combine(genres)
        hasher.combine(studioNames)
    }

    static func == (lhs: ItemQuery, rhs: ItemQuery) -> Bool {
        lhs.parentID == rhs.parentID &&
        lhs.sortBy == rhs.sortBy &&
        lhs.genres == rhs.genres &&
        lhs.studioNames == rhs.studioNames &&
        lhs.isFavorite == rhs.isFavorite
    }
}
