import SwiftUI

struct HomeView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel: HomeViewModel?
    @State private var selectedItem: JellyfinItem?
    @State private var selectedFilter: FilterDestination?

    /// Spinner accent: HomeView's NavigationStack resets the inherited TabView tint to white, so re-apply the effective tint to match the Live TV spinner.
    private var spinnerTint: Color {
        dependencies.appearancePreferences.effectiveTint(
            isSupporter: dependencies.storeKitService.isSupporter
        ) ?? Color.accentColor
    }

    /// Which content row holds focus; nil when focus leaves the rows (Up from the top row to the tab bar). Drives auto-scroll-to-top so the tab bar isn't clipped on arrival from below.
    @FocusState private var focusedRowIndex: Int?

    /// Debounce for the focus-left-rows → scroll-to-top, cancelled/respawned on focus change; without it transient nils between row transitions trigger spurious scroll-to-top snaps.
    @State private var scrollResetTask: Task<Void, Never>?

    /// Last serverDidSwitch this view reacted to. .task(id:) re-fires with the same id on every reappear; without the latch each reappear would wipe FilterCache and reload the whole feed.
    @State private var lastHandledServerSwitch = 0

    private static let refreshStaleSeconds: TimeInterval = 60

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    if vm.isLoading {
                        ProgressView()
                            .tint(spinnerTint)
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
                        .tint(spinnerTint)
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
                // Pick up new server-side content on return after 60 s: tight enough to show additions fast, loose enough that tab-hopping doesn't spam the server.
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
        .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidChange)) { note in
            // Patch the tile progress in place from the payload (race-free), then reload for structural changes (reorder, finished drop-out), then re-apply so a stale cached re-fetch can't regress the bar (issue #24).
            let itemID = note.userInfo?[PlaybackProgressKey.itemID] as? String
            let ticks = note.userInfo?[PlaybackProgressKey.positionTicks] as? Int64
            Task { @MainActor in
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
                await viewModel?.loadContent()
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeItemDidDelete)) { _ in
            // Reload so the deleted item drops out immediately instead of lingering until the next stale refresh.
            Task { await viewModel?.loadContent() }
        }
        .onChange(of: appState.activeUser?.id) { _, newValue in
            // Profile switch: tear down the old VM so .onAppear rebuilds it with the new userID (else it keeps loading the previous profile's permissions/watch state).
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
            // Roll the latch back if cancelled mid-reload so the reappear re-fire finishes the job instead of being guarded away.
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
                // Invisible zero-height scroll-to-top anchor for when focus leaves the rows.
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
                        // Hide zero-match tiles. nil count = not yet computed, so first-run shows everything until the background precompute fills the dict and empties fade out.
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
                // Scroll to top only on a real top-row → tab-bar arrival, gated two ways:
                // 1. oldValue == 0: the focus engine routes Up to the tab bar only from the top row; a row-N→nil (N>0) is a transient between LazyVStack row materializations, not a tab-bar arrival.
                // 2. 200ms debounce: even a legit row-0→tab-bar transition (and a down-scroll past row 0) passes through nil for a beat; 200ms outlasts those transients but still feels immediate.
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
        // A provider tile filters the LOCAL library by Studio (pipe-joined aliases catch "Disney+" and "Walt Disney Pictures"), augmented by the smart-provider TMDB watch-provider hint so studio-tag-less titles surface (Modern Family on Disney+, Bluey via Ludo Studio).
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

    /// Convenience over FilterCacheKey.Home so CatalogProvider call sites don't reach into the id field themselves.
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
                // Without a cacheKey FilteredGridView.init falls to the empty-state branch with isLoading=true on every visit (the brief flash on opening a genre tile). Tag name is a stable enough key.
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
        // My Media tile browses one library in the shared grid; parentID scopes it, types match the library.
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
    /// TMDB watch-provider id augmenting the studio filter with Jellyseerr's live "streaming now" list, picking up studio-tag-less titles (Modern Family on Disney+, Suits on Netflix). nil runs only the studio match.
    var smartProviderID: Int?
    /// ISO 3166-1 alpha-2 region for smartProviderID; TMDB watch-provider data is region-specific (Disney+ DE != US), defaults to Locale.current.
    var smartProviderRegion: String?
    /// Stable key for FilteredGridView's result cache, independent of smartProviderID so broadcast-only tiles (ABC/NBC/CBS) still cache and feed the empty-tile-hide pass.
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
