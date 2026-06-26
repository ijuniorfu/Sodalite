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
    @State private var versionChoice: VersionPickerChoice?
    @State private var pendingSourceID: String?
    /// Latched on an actual version pick so the sheet's onDismiss launches the player on a pick but not a cancel.
    @State private var didPickVersion = false
    @State private var showTrailer = false
    @State private var trailerItem: JellyfinItem?
    @State private var isPresentingDeleteSheet: Bool = false
    @FocusState private var playButtonFocused: Bool

    let item: JellyfinItem

    /// EnableContentDeletion (or admin) on the active user; read reactively from AppState.activeUser so a profile switch updates visibility without a manual refresh.
    private var canDelete: Bool {
        appState.activeUser?.canDeleteContent == true
    }

    var body: some View {
        ZStack {
            // Solid black under the loading state (contentView paints its own backdrop), see SeriesDetailView.
            Color.black.ignoresSafeArea()

            if let vm = viewModel, !vm.isLoading {
                contentView(vm: vm)
                    .transition(.opacity)
            } else {
                // Centred spinner; gating on isLoading lands one finished frame instead of a field-fill repaint (SeriesDetailView rationale).
                ZStack {
                    ProgressView()
                    // Invisible focus anchor so a Menu press during load pops back instead of quitting the app.
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
                    preferredMediaSourceID: pendingSourceID,
                    tintColor: dependencies.appearancePreferences.effectiveTint(
                        isSupporter: dependencies.storeKitService.isSupporter
                    )
                )
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if let userID = appState.activeUser?.id {
                PlayerLauncher(
                    isPresented: $showTrailer,
                    item: showTrailer ? trailerItem : nil,
                    startFromBeginning: true,
                    playbackService: dependencies.jellyfinPlaybackService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    // Trailer is a distinct server item; the movie's
                    // cached PlaybackInfo does not apply to it.
                    cachedPlaybackInfo: nil,
                    tintColor: dependencies.appearancePreferences.effectiveTint(
                        isSupporter: dependencies.storeKitService.isSupporter
                    )
                )
                .allowsHitTesting(false)
            }
        }
        .sheet(item: $versionChoice, onDismiss: {
            if didPickVersion {
                didPickVersion = false
                showPlayer = true
            }
        }) { choice in
            VersionPickerSheet(
                sources: choice.sources,
                tintColor: dependencies.appearancePreferences.effectiveTint(
                    isSupporter: dependencies.storeKitService.isSupporter
                )
            ) { source in
                pendingSourceID = source.id
                playFromBeginning = choice.fromBeginning
                didPickVersion = true
                versionChoice = nil
            }
        }
        .onChange(of: showTrailer) { _, isPlaying in
            if !isPlaying {
                trailerItem = nil
                deferOnMain(by: 0.1) { playButtonFocused = true }
            }
        }
        .onChange(of: showPlayer) { _, isPlaying in
            if !isPlaying {
                deferOnMain(by: 0.1) {
                    playButtonFocused = true
                }
            }
        }
        // Posted once Jellyfin confirms the stop position. Patch in place from the payload (race-free); refreshResumePosition only reconciles played/favorite, then the patch is re-applied so a stale cached re-fetch can't regress the just-played position (issue #24).
        .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidChange)) { note in
            let itemID = note.userInfo?[PlaybackProgressKey.itemID] as? String
            let ticks = note.userInfo?[PlaybackProgressKey.positionTicks] as? Int64
            Task { @MainActor in
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
                await viewModel?.refreshResumePosition()
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
            }
        }
        // AppRouter bumps this on every deep-link arrival so a TopShelf tap on a different item tears down the active player session and surfaces the new detail sheet cleanly.
        .onChange(of: appState.requestPlayerDismissal) { _, _ in
            if showPlayer { showPlayer = false }
        }
        // Play button is out of the tree at first paint; push focus once isLoading flips false. Tiny defer dodges the focus-commit race.
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
                .hidesShellTabBar()
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
                            // Drop the on-disk filter cache so Library/Home rows don't keep showing the deleted movie until natural eviction.
                            FilterCache.shared.clearAll()
                            NotificationCenter.default.post(name: .homeItemDidDelete, object: nil)
                            // Pop after the sheet's success-toast hold.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(1100))
                                popDetail()
                            }
                            return .success
                        } catch {
                            return .from(error)
                        }
                    }
                )
            }
        }
    }

    private func contentView(vm: DetailViewModel) -> some View {
        ZStack {
            DetailBackdrop(
                imageURL: vm.backdropURL(for: vm.item),
                posterFallbackURL: vm.posterURL(for: vm.item)
            )
                .id(vm.item.backdropImageTags?.first ?? "empty")

            DetailContentOverlay(hero: {
                DetailHeroLogo(viewModel: vm)
            }, primary: {
                // Glass panel + action buttons as the bottom-aligned first-page block (Sodalite#15 round 6), mirroring SeriesDetailView.
                VStack(alignment: .leading, spacing: 24) {
                    glassPanel(vm: vm)
                    actionButtonRow(vm: vm)
                }
                .padding(.horizontal, 50)
                .id(vm.item.genres?.first ?? vm.item.name)
            }) {
                if let overview = vm.item.overview, !overview.isEmpty {
                    ExpandableTextBox(text: overview)
                        .padding(.horizontal, 50)
                } else if !vm.hasFullDetail {
                    // Overview in flight after a snapshot paint: reserve the footprint (Sodalite#15).
                    ExpandableTextBoxPlaceholder()
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
            // Title/logo lives in the hero slot (see DetailContentOverlay); panel opens into the metadata row.
            if vm.item.type == .episode, let series = vm.item.seriesName {
                Text(episodeSubtitle(vm: vm, seriesName: series))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            // Metadata+tagline row one, genres+credits row two, baseline-aligned so columns sit level.
            DetailInfoRows(
                item: vm.item,
                hasFullDetail: vm.hasFullDetail,
                hasLeftSecondary: !(vm.item.genres?.isEmpty ?? true)
            ) {
                ItemMetadataRow(item: vm.item)
            } leftSecondary: {
                if let genres = vm.item.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    /// Version picker vs direct start; movies carry their media sources from the detail fetch, so the count check is reliable.
    private func requestPlay(fromBeginning: Bool, vm: DetailViewModel) {
        if let sources = vm.item.mediaSources, sources.count > 1 {
            versionChoice = VersionPickerChoice(
                item: vm.item,
                sources: sources,
                fromBeginning: fromBeginning,
                fromPlayButton: false
            )
        } else {
            playFromBeginning = fromBeginning
            pendingSourceID = nil
            showPlayer = true
        }
    }

    // MARK: - Action Buttons

    /// Button row below the glass panel, outside it (Sodalite#15 round 6); each GlassActionButton carries its own material so the row needs no plate.
    private func actionButtonRow(vm: DetailViewModel) -> some View {
        HStack(spacing: 16) {
            GlassActionButton(
                title: playButtonTitle(vm: vm),
                systemImage: "play.fill",
                isProminent: true,
                subtitle: resumeTimestamp(vm: vm),
                progressFraction: playProgressFraction(vm: vm),
                action: {
                    requestPlay(fromBeginning: false, vm: vm)
                }
            )
            .focused($playButtonFocused)

            if hasProgress(vm: vm) {
                GlassActionButton(
                    title: "detail.replay",
                    systemImage: "arrow.counterclockwise",
                    action: {
                        requestPlay(fromBeginning: true, vm: vm)
                    }
                )
            }

            if vm.hasLocalTrailer {
                GlassActionButton(
                    title: "detail.trailer",
                    systemImage: "play.rectangle",
                    action: {
                        Task {
                            if let trailer = await vm.loadTrailer() {
                                trailerItem = trailer
                                showTrailer = true
                            }
                        }
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

            // No "Request in Seerr" on movie detail: the movie is already in Jellyfin. The button stays on series detail for continuing shows.

            GlassActionButton(
                title: vm.isPlayed ? "detail.markUnwatched" : "detail.markWatched",
                systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                action: { Task { await vm.togglePlayed() } }
            )

            // Episodes only reach here via DetailRouterView's no-parent-series fallback; per-episode deletion isn't supported (delete lives on series detail, matching SeriesDetailView's !isShowingEpisode guard).
            if canDelete && item.type != .episode {
                GlassActionButton(
                    title: "detail.delete.button",
                    systemImage: "trash",
                    isDestructive: true,
                    action: { isPresentingDeleteSheet = true }
                )
            }
        }
        .collapsesActionButtonLabel()
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

    /// Formatted resume timestamp for the play-button subtitle, or nil when there's nothing to resume (fresh or finished).
    private func resumeTimestamp(vm: DetailViewModel) -> String? {
        guard let ticks = vm.item.userData?.playbackPositionTicks, ticks > 0 else {
            return nil
        }
        return ResumeTimeFormatter.format(ticks: ticks)
    }

    /// 0…1 progress for the play button's overlay; nil when fresh or no run-time metadata.
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

    /// Resolve a cast member to a TMDB person id and open the person page; inert when the server has no TMDB id.
    private func handlePersonTap(_ member: CastMember) {
        resolvePersonRoute(
            for: member,
            userID: appState.activeUser?.id,
            itemService: dependencies.jellyfinItemService
        ) { navigateToPerson = $0 }
    }
}
