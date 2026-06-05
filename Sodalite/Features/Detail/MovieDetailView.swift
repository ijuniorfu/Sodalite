import SwiftUI

struct MovieDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DetailViewModel?
    @State private var navigateToSeries: JellyfinItem?
    @State private var navigateToItem: JellyfinItem?
    @State private var navigateToPerson: PersonRoute?
    @State private var showPlayer = false
    @State private var playFromBeginning = false
    @State private var isPresentingDeleteSheet: Bool = false
    @FocusState private var playButtonFocused: Bool

    let item: JellyfinItem

    /// True when the active user has Jellyfin's EnableContentDeletion
    /// flag (or is an administrator). Read reactively from
    /// AppState.activeUser, so a profile switch updates the visibility
    /// without a manual refresh.
    private var canDelete: Bool {
        appState.activeUser?.canDeleteContent == true
    }

    var body: some View {
        ZStack {
            // Solid black underneath the loading state, see
            // SeriesDetailView. The contentView already paints its
            // own backdrop, so this only shows through during load.
            Color.black.ignoresSafeArea()

            if let vm = viewModel, !vm.isLoading {
                contentView(vm: vm)
                    .transition(.opacity)
            } else {
                // Centred spinner while detail + similar are still
                // in flight. See SeriesDetailView for the same
                // rationale: progressively-filling fields produce a
                // visible repaint when the play button's resume
                // metadata + progress overlay land mid-render. One
                // finished frame reads quieter than three.
                ZStack {
                    ProgressView()
                    // Invisible focus anchor so a Menu press during
                    // load pops back to the previous screen instead
                    // of escaping the navigation stack and quitting
                    // the app.
                    Button("") { dismiss() }
                        .opacity(0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel?.isLoading)
        .ignoresSafeArea()
        .overlay {
            if let userID = appState.activeUser?.id {
                PlayerLauncher(
                    isPresented: $showPlayer,
                    item: showPlayer ? (viewModel?.item ?? item) : nil,
                    startFromBeginning: playFromBeginning,
                    playbackService: dependencies.jellyfinPlaybackService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    cachedPlaybackInfo: viewModel?.cachedPlaybackInfo,
                    tintColor: dependencies.appearancePreferences.effectiveTint(
                        isSupporter: dependencies.storeKitService.isSupporter
                    )
                )
                .allowsHitTesting(false)
            }
        }
        .onChange(of: showPlayer) { _, isPlaying in
            if !isPlaying {
                deferOnMain(by: 0.1) {
                    playButtonFocused = true
                }
            }
        }
        // AppRouter bumps this counter on every deep-link arrival so
        // a TopShelf tap on a different item can tear down the active
        // player session and let the new detail sheet surface cleanly.
        .onChange(of: appState.requestPlayerDismissal) { _, _ in
            if showPlayer { showPlayer = false }
        }
        // Loading-gate now blocks the play button from existing in
        // the view hierarchy at first paint, so the focus engine has
        // nothing to land on when the modal appears. Push the focus
        // explicitly once isLoading flips false and the button is in
        // the tree. Tiny defer dodges the same focus-commit race the
        // post-player return path already works around.
        .onChange(of: viewModel?.isLoading) { _, loading in
            if loading == false {
                deferOnMain(by: 0.1) {
                    playButtonFocused = true
                }
            }
        }
        .navigationDestination(item: $navigateToItem) { item in
            DetailRouterView(item: item)
        }
        .navigationDestination(item: $navigateToSeries) { series in
            SeriesDetailView(item: series)
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(item: $navigateToPerson) { route in
            PersonDetailView(personID: route.tmdbID, personName: route.name)
        }
        .onAppear {
            if viewModel == nil, let userID = appState.activeUser?.id {
                viewModel = DetailViewModel(
                    item: item,
                    itemService: dependencies.jellyfinItemService,
                    imageService: dependencies.jellyfinImageService,
                    userID: userID,
                    libraryService: dependencies.jellyfinLibraryService,
                    playbackService: dependencies.jellyfinPlaybackService
                )
                Task { await viewModel?.loadFullDetail() }
            }
        }
        .sheet(isPresented: $isPresentingDeleteSheet) {
            if let vm = viewModel {
                let popDetail = dismiss
                MediaDeletionSheet(
                    mode: .movie(
                        itemID: vm.item.id,
                        tmdbID: vm.item.tmdbID,
                        title: vm.item.name
                    ),
                    onConfirm: { request in
                        do {
                            try await dependencies.mediaDeletionService.deleteMovie(
                                itemID: vm.item.id,
                                tmdbID: vm.item.tmdbID,
                                cascadeToArrStack: request.cascadeToArrStack
                            )
                            // Drop the on-disk filter cache so the
                            // Library + Home rows don't keep showing
                            // the deleted movie until natural eviction.
                            // Active rows re-fetch on next focus.
                            FilterCache.shared.clearAll()
                            // Tell Home to reload so the deleted movie
                            // drops out of its rows right away.
                            NotificationCenter.default.post(name: .homeItemDidDelete, object: nil)
                            // Pop the detail view after the sheet's
                            // success-toast hold completes.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(1100))
                                popDetail()
                            }
                            return .success
                        } catch let error as MediaDeletionError {
                            if error.reason == .seerrNotSignedIn {
                                return .partialSuccess(
                                    message: String(localized: "delete.toast.seerrNotSignedIn")
                                )
                            }
                            if error.partialSuccess {
                                return .partialSuccess(
                                    message: String(localized: "delete.toast.partialSuccess")
                                )
                            } else {
                                return .failure(
                                    message: String(localized: "delete.toast.failure")
                                )
                            }
                        } catch {
                            return .failure(
                                message: String(localized: "delete.toast.failure")
                            )
                        }
                    }
                )
            }
        }
    }

    private func contentView(vm: DetailViewModel) -> some View {
        ZStack {
            DetailBackdrop(imageURL: vm.backdropURL(for: vm.item))
                .id(vm.item.backdropImageTags?.first ?? "empty")

            DetailContentOverlay {
                glassPanel(vm: vm)
                    .padding(.horizontal, 50)
                    .id(vm.item.genres?.first ?? vm.item.name)

                if let overview = vm.item.overview, !overview.isEmpty {
                    ExpandableTextBox(text: overview)
                        .padding(.horizontal, 50)
                }

                if vm.item.mediaStreams != nil || vm.item.mediaSources != nil {
                    TechInfoBox(item: vm.item)
                }

                if let people = vm.item.people, !people.isEmpty {
                    MediaCastRow(
                        members: jellyfinCastMembers(
                            from: people,
                            imageService: dependencies.jellyfinImageService
                        ),
                        onSelect: { handlePersonTap($0) }
                    )
                }

                if !vm.similarItems.isEmpty {
                    HorizontalMediaRow(
                        title: "detail.similar",
                        items: vm.similarItems,
                        imageURLProvider: { vm.posterURL(for: $0) },
                        onItemSelected: { navigateToItem = $0 },
                        cardStyle: .poster
                    )
                }
            }
        }
    }

    // MARK: - Glass Panel

    private func glassPanel(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ContentLogoTitle(
                itemID: vm.item.id,
                logoTag: vm.item.imageTags?.logo,
                maxHeight: 130
            ) {
                Text(vm.item.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }

            // Episode subtitle
            if vm.item.type == .episode, let series = vm.item.seriesName {
                Text(episodeSubtitle(vm: vm, seriesName: series))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 16) {
                    ItemMetadataRow(item: vm.item)

                    // Genres
                    if let genres = vm.item.genres, !genres.isEmpty {
                        Text(genres.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Action buttons
                    HStack(spacing: 16) {
                        GlassActionButton(
                            title: playButtonTitle(vm: vm),
                            systemImage: "play.fill",
                            isProminent: true,
                            subtitle: resumeTimestamp(vm: vm),
                            progressFraction: playProgressFraction(vm: vm),
                            action: {
                                playFromBeginning = false
                                showPlayer = true
                            }
                        )
                        .focused($playButtonFocused)

                        if hasProgress(vm: vm) {
                            GlassActionButton(
                                title: "detail.replay",
                                systemImage: "arrow.counterclockwise",
                                action: {
                                    playFromBeginning = true
                                    showPlayer = true
                                }
                            )
                        }

                        if vm.item.type != .episode {
                            GlassActionButton(
                                title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
                                systemImage: vm.isFavorite ? "heart.fill" : "heart",
                                action: { Task { await vm.toggleFavorite() } }
                            )
                        }

                        if vm.item.type == .episode, let seriesId = vm.item.seriesId {
                            GlassActionButton(
                                title: "detail.showSeries",
                                systemImage: "tv",
                                action: {
                                    navigateToSeries = JellyfinItem(
                                        seriesStub: seriesId,
                                        name: vm.item.seriesName ?? ""
                                    )
                                }
                            )
                        }

                        // No "Request in Seerr" button on movie detail: if we're
                        // showing this view the movie is already in Jellyfin, so
                        // the request flow has nothing meaningful to offer. The
                        // button stays on the series detail for continuing shows
                        // where new seasons may still land.

                        GlassActionButton(
                            title: vm.isPlayed ? "detail.markUnwatched" : "detail.markWatched",
                            systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                            action: { Task { await vm.togglePlayed() } }
                        )

                        // Episodes only reach MovieDetailView via the
                        // no-parent-series fallback in DetailRouterView
                        // (episodes with a seriesId open in SeriesDetailView).
                        // Per-episode deletion is not a supported flow either
                        // way: the delete entry point lives on the parent
                        // series detail, matching SeriesDetailView's own
                        // !isShowingEpisode guard.
                        if canDelete && item.type != .episode {
                            GlassActionButton(
                                title: "detail.delete.button",
                                systemImage: "trash",
                                isDestructive: true,
                                action: { isPresentingDeleteSheet = true }
                            )
                        }
                    }
                    .padding(.top, 4)
                }

                if DetailSecondaryInfo.hasContent(vm.item) {
                    Spacer(minLength: 24)
                    DetailSecondaryInfo(item: vm.item)
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    // MARK: - Helpers

    private func hasProgress(vm: DetailViewModel) -> Bool {
        if let ticks = vm.item.userData?.playbackPositionTicks, ticks > 0 { return true }
        return false
    }

    private func playButtonTitle(vm: DetailViewModel) -> LocalizedStringKey {
        if hasProgress(vm: vm) { return "detail.resume" }
        return "detail.play"
    }

    /// Returns the formatted resume timestamp for the play-button
    /// subtitle slot, or nil when there's nothing to resume from
    /// (a fresh item, or an item that's already been finished).
    private func resumeTimestamp(vm: DetailViewModel) -> String? {
        guard let ticks = vm.item.userData?.playbackPositionTicks, ticks > 0 else {
            return nil
        }
        return ResumeTimeFormatter.format(ticks: ticks)
    }

    /// 0…1 progress fraction surfaced as the resume-progress overlay
    /// inside the play button. nil when the movie is fresh or has no
    /// run-time metadata.
    private func playProgressFraction(vm: DetailViewModel) -> Double? {
        guard let ticks = vm.item.userData?.playbackPositionTicks, ticks > 0,
              let total = vm.item.runTimeTicks, total > 0 else {
            return nil
        }
        return min(1.0, max(0.0, Double(ticks) / Double(total)))
    }

    private func episodeSubtitle(vm: DetailViewModel, seriesName: String) -> String {
        var parts = [seriesName]
        if let s = vm.item.parentIndexNumber { parts.append("S\(s)") }
        if let e = vm.item.indexNumber { parts.append("E\(e)") }
        return parts.joined(separator: " · ")
    }

    /// Resolve a Jellyfin cast member to a TMDB person id, then open the
    /// person page. Inert when the server has no TMDB id for them.
    private func handlePersonTap(_ member: CastMember) {
        guard let jid = member.jellyfinPersonID,
              let userID = appState.activeUser?.id else { return }
        Task {
            if let person = try? await dependencies.jellyfinItemService.getItemDetail(
                   userID: userID, itemID: jid
               ),
               let tmdb = person.tmdbID {
                navigateToPerson = PersonRoute(tmdbID: tmdb, name: member.name)
            }
        }
    }
}
