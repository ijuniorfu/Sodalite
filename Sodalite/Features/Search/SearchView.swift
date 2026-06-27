import SwiftUI

struct SearchView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel: SearchViewModel?
    @State private var selectedJellyfinItem: JellyfinItem?
    @State private var selectedSeerrMedia: SeerrMedia?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                if let vm = viewModel {
                    if vm.jellyfinResults.isEmpty && vm.seerrResults.isEmpty {
                        emptyState(vm: vm)
                    } else {
                        resultsView(vm: vm)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Full-screen cover (over the tab bar) instead of a push: the bar is never hidden/removed, so it is never re-templated gray on return (tvOS 26). See detailCover.
            .detailCover(item: $selectedJellyfinItem) { item in
                DetailRouterView(item: item)
            }
            .detailCover(item: $selectedSeerrMedia) { media in
                CatalogDetailView(media: media)
            }
        }
        .onAppear(perform: bootstrap)
        // Reactive Seerr hookup: bootstrap captures isSeerrConnected once, so hitting Search before restoreSession finishes the Seerr part would pin a nil service for the session. Re-sync on flag change keeps the catalog half live.
        .onChange(of: appState.isSeerrConnected) { _, connected in
            viewModel?.seerrSearchService = connected ? dependencies.seerrSearchService : nil
            // Re-run the active query so the Seerr half catches up without retyping.
            viewModel?.scheduleSearch()
        }
        .onChange(of: appState.activeUser?.id) { _, newValue in
            // Profile switch: drop the VM so .onAppear rebuilds for the new user (mirrors HomeView); keeping it pins the old userID into /Users/{id}/Items searches, 403ing the new token.
            viewModel = nil
            guard newValue != nil else { return }
            bootstrap()
        }
        // Pre-warm the poster cache on results-change so first focus doesn't pay round-trip + decode. Bounded-concurrency prefetch so it doesn't starve foreground bandwidth.
        .onChange(of: viewModel?.jellyfinResults) { _, _ in
            prefetchSearchPosters()
        }
        .onChange(of: viewModel?.seerrResults) { _, _ in
            prefetchSearchPosters()
        }
    }

    /// Hand current result poster URLs to `ImageCache.prefetch`; cached URLs are skipped, so only new posters pay network on each results-change.
    private func prefetchSearchPosters() {
        guard let vm = viewModel else { return }
        var urls: [URL] = []
        for item in vm.jellyfinResults {
            if let url = dependencies.jellyfinImageService.posterURL(for: item) {
                urls.append(url)
            }
        }
        for media in vm.seerrResults {
            if let url = SeerrImageURL.poster(path: media.posterPath) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        let token = dependencies.jellyfinClient.accessToken
        let host = dependencies.jellyfinClient.baseURL?.host
        Task.detached(priority: .utility) {
            await ImageCache.prefetch(urls, authToken: token, jellyfinHost: host)
        }
    }

    /// Inline UIKit UITextField bar: SwiftUI TextField routes focus unreliably on tvOS (silently skipped); .searchable() adds a 1-2s rebuild per tab-switch. UITextField routes reliably with no switch-lag.
    @ViewBuilder
    private var searchBar: some View {
        if let vm = viewModel {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SearchTextField(
                    text: Bindable(vm).query,
                    placeholder: String(localized: "search.placeholder", defaultValue: "Search")
                )
                .frame(maxWidth: .infinity, maxHeight: 42)
                .onChange(of: vm.query) { _, _ in
                    vm.scheduleSearch()
                }

                if vm.isSearching {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.08))
            )
            .padding(.horizontal, 80)
            .padding(.top, 38)
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private func resultsView(vm: SearchViewModel) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                if !vm.jellyfinResults.isEmpty {
                    librarySection(items: vm.jellyfinResults)
                }
                if !vm.seerrResults.isEmpty {
                    catalogSection(items: vm.seerrResults)
                }
                if vm.isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 40)
                }
            }
            .padding(.vertical, 20)
        }
    }

    private func librarySection(items: [JellyfinItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "house.fill", title: "search.section.library", tint: .accentColor)
                .padding(.horizontal, 50)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 30) {
                    ForEach(items) { item in
                        FocusableCard {
                            selectedJellyfinItem = item
                        } content: { isFocused in
                            MediaCard(
                                item: item,
                                imageURL: dependencies.jellyfinImageService.imageURL(
                                    itemID: item.id,
                                    imageType: .primary,
                                    tag: item.imageTags?.primary,
                                    maxWidth: 440
                                ),
                                style: .poster,
                                isFocused: isFocused
                            )
                        }
                    }
                }
                .padding(.horizontal, 50)
                .padding(.vertical, 20)
            }
            // .focusSection() so vertical nav crosses row boundaries when geometry doesn't line up (right-side catalog card over a one-item library row); else up-press finds nothing overhead and dies.
            .focusSectionCompat()
        }
    }

    private func catalogSection(items: [SeerrMedia]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "tray.and.arrow.down", title: "search.section.catalog", tint: .orange)
                .padding(.horizontal, 50)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 30) {
                    ForEach(items) { media in
                        FocusableCard {
                            selectedSeerrMedia = media
                        } content: { isFocused in
                            SeerrMediaCard(media: media, isFocused: isFocused)
                        }
                    }
                }
                .padding(.horizontal, 50)
                .padding(.vertical, 20)
            }
            .focusSectionCompat()
        }
    }

    private func sectionHeader(icon: String, title: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private func emptyState(vm: SearchViewModel) -> some View {
        if vm.isSearching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = vm.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text(errorMessage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.query.trimmingCharacters(in: .whitespaces).count < 2 {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("search.hint.startTyping")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if !appState.isSeerrConnected {
                    Text("search.hint.connectSeerr")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("search.empty.noResults")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bootstrap() {
        guard viewModel == nil, let userID = appState.activeUser?.id else { return }
        viewModel = SearchViewModel(
            itemService: dependencies.jellyfinItemService,
            seerrSearchService: appState.isSeerrConnected ? dependencies.seerrSearchService : nil,
            userID: userID
        )
    }
}

