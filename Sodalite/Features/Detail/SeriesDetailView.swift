import SwiftUI

struct SeriesDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DetailViewModel?
    @State private var selectedEpisode: JellyfinItem?
    @State private var navigateToItem: JellyfinItem?
    @State private var navigateToPerson: PersonRoute?
    @State private var navigateToSeerrRequest: SeerrMedia?
    @State private var backdropURL: URL?
    @State private var showPlayer = false
    @State private var playItem: JellyfinItem?
    @State private var playFromBeginning = false
    /// True when the player was launched from the prominent Play
    /// button in the glass panel; false when it was launched from
    /// an episode card in the episode row. Used by the player-dismiss
    /// handler to restore focus to the actual control the user
    /// interacted with, without it, the user always landed back on the
    /// episode-card row even after pressing the Play button, which
    /// looked correct (Play button still showed a residual highlight)
    /// but pressing Down jumped past the seasons row straight to the
    /// cast row below the episodes.
    @State private var playOriginatedFromPlayButton = false
    /// Captured ScrollViewProxy for the outer vertical ScrollView in
    /// DetailContentOverlay. The player-dismiss handler uses it to
    /// scroll back to the episode row when restoring focus to the
    /// just-played episode, otherwise the nil-flicker focus transition
    /// left the page stuck at the top.
    @State private var episodeRowScrollProxy: ScrollViewProxy?
    @FocusState private var focusedSeasonID: String?
    @FocusState private var focusedEpisodeID: String?
    @FocusState private var focusBridgeActive: Bool
    /// Drives the initial focus once the loading gate releases,
    /// the play button only enters the view hierarchy after
    /// isLoading flips false, so the focus engine has nothing to
    /// auto-land on at first paint. We push focus explicitly via
    /// .onChange below.
    @FocusState private var playButtonFocused: Bool
    @State private var isPresentingDeleteSheet: Bool = false
    /// Set when "Show Details" is chosen from an episode's context menu.
    /// The context menu restores focus to its anchor card on dismiss, so
    /// the focusedEpisodeID observer uses this flag to bounce focus up to
    /// the play button instead of leaving it on the row.
    @State private var pendingPlayFocusAfterMenu = false

    /// True when the active user has Jellyfin's EnableContentDeletion
    /// flag (or is an administrator). Read reactively from
    /// AppState.activeUser, so a profile switch updates the visibility
    /// without a manual refresh.
    private var canDelete: Bool {
        appState.activeUser?.canDeleteContent == true
    }

    /// Convert engine-side season objects into the shape
    /// MediaDeletionSheet wants for its multi-select picker.
    private func deletionSeasonOptions(from seasons: [JellyfinItem]) -> [MediaDeletionSheet.SeasonOption] {
        seasons.map { season in
            MediaDeletionSheet.SeasonOption(
                id: season.id,
                seasonNumber: season.indexNumber ?? 0,
                title: season.name
            )
        }
    }

    @State private var episodeRedirectDone = false
    /// Sticky flag: set when the episode row had focus so that the
    /// season bar's onChange can tell "user scrolled up from episodes"
    /// apart from "user is tabbing between season tabs". Used to snap
    /// the focus back to the currently playing season when the user
    /// scrolls back up, without it, tvOS lands on whichever tab is
    /// geographically above the last focused episode, which may be
    /// two seasons away from what's actually being shown.
    @State private var episodesHadFocus = false
    /// Tracks the last focused region inside the season + episode
    /// block. The invisible focus bridge between the two rows reads
    /// this to decide which direction a cross-row focus jump came
    /// from, without having to inspect @FocusState during the
    /// transition (which is already nil by that point).
    @State private var lastFocusedArea: FocusArea = .none
    private enum FocusArea { case none, season, episode }
    /// When the bridge transitions from season → episode, it writes
    /// the desired episode id here. The episode-row's ScrollViewReader
    /// observes the change, scrolls to that id (so the LazyHStack
    /// materialises the card if the list was scrolled away), then
    /// writes focusedEpisodeID. Without this round-trip, a write to
    /// focusedEpisodeID for a card outside the rendered window was a
    /// silent no-op, that's the right-side-takes-two-clicks case.
    @State private var pendingEpisodeFocus: String?

    let item: JellyfinItem
    /// When the view was opened from a specific episode (via
    /// DetailRouterView's .episode route), this seeds the preselected
    /// episode so the panel paints from the snapshot immediately and
    /// the view model lands on the right season. nil for a normal
    /// series open.
    var initialEpisode: JellyfinItem? = nil

    private var displayItem: JellyfinItem {
        selectedEpisode ?? viewModel?.item ?? item
    }

    private var isShowingEpisode: Bool {
        selectedEpisode != nil
    }

    var body: some View {
        ZStack {
            // Solid black behind the spinner, the backdrop image is
            // distracting next to the loading indicator (and may
            // still be fading in from network) so we hold it back
            // until the content is ready to crossfade in over it.
            Color.black.ignoresSafeArea()

            if let vm = viewModel, !vm.isLoading {
                DetailBackdrop(imageURL: backdropURL)
                    .id(backdropURL?.absoluteString ?? "empty")
                    .transition(.opacity)
            }

            if let vm = viewModel, !vm.isLoading {
                DetailContentOverlay {
                    // Captured ScrollViewProxy lets the player-dismiss
                    // handler scroll the outer vertical ScrollView back
                    // to the episode row. Without this, the nil-flicker
                    // focus restore triggered tvOS's "scroll to bring
                    // focus into view" against an intermediate
                    // not-yet-rendered state and the page jumped to the
                    // top, even though logical focus eventually landed
                    // on the just-played episode card.
                    ScrollViewReader { outerProxy in
                        VStack(alignment: .leading, spacing: 40) {
                            glassPanel(vm: vm)
                                .padding(.horizontal, 50)
                                .id("\(vm.item.id)-\(vm.item.genres?.count ?? 0)-\(vm.isLoading)")
                                .animation(.easeInOut(duration: 0.3), value: selectedEpisode?.id)

                            if let overview = displayItem.overview, !overview.isEmpty {
                                ExpandableTextBox(text: overview)
                                    .padding(.horizontal, 50)
                                    .id(displayItem.id)
                            }

                            if displayItem.mediaStreams != nil || displayItem.mediaSources != nil {
                                TechInfoBox(item: displayItem)
                                    .animation(.easeInOut(duration: 0.3), value: selectedEpisode?.id)
                            }

                            if !vm.seasons.isEmpty {
                                seasonSection(vm: vm)
                                    .id("episodeRow")
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
                        .onAppear {
                            episodeRowScrollProxy = outerProxy
                        }
                    }
                }
                .transition(.opacity)
            } else {
                // Centred spinner over the backdrop while every
                // section's data is still in flight. Showing the
                // panel progressively as fields fill in produced a
                // visible repaint storm (play button title + subtitle
                // + progress overlay all changed in a 300 ms window);
                // gating on isLoading lets the user land on a
                // single, finished render.
                ZStack {
                    ProgressView()
                    // Invisible focus anchor, without it, pressing
                    // Menu on the loading screen propagates past the
                    // navigation stack and quits the app instead of
                    // popping back. Same pattern other empty/loading
                    // states in the app use.
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
                    item: playItem,
                    startFromBeginning: playFromBeginning,
                    playbackService: dependencies.jellyfinPlaybackService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    cachedPlaybackInfo: playItem.flatMap { ep in
                        (viewModel?.currentEpisodeID == ep.id) ? viewModel?.cachedPlaybackInfo : nil
                    },
                    tintColor: dependencies.appearancePreferences.effectiveTint(
                        isSupporter: dependencies.storeKitService.isSupporter
                    )
                )
                .allowsHitTesting(false)
            }
        }
        .onChange(of: showPlayer) { _, isPlaying in
            if !isPlaying {
                // Restore focus to the control the user actually
                // interacted with: the Play button if they tapped
                // that, the episode card if they tapped a card.
                // Always restoring to the episode card was the
                // previous behaviour, which looked wrong after a
                // Play-button launch, the Play button still showed a
                // residual focus glow, but pressing Down jumped past
                // the seasons row straight to cast because logical
                // focus was actually on the episode card below.
                //
                // Two-step write (nil, then the target) forces a real
                // state transition; without it, writing the same
                // FocusState value back is a no-op, and the focus
                // engine doesn't refresh. DispatchQueue.main.async
                // gets the second write into the next runloop tick so
                // SwiftUI batches it into the same render cycle as
                // the nil, the user never sees an intermediate "no
                // focus" or Play-button flash.
                if playOriginatedFromPlayButton {
                    playButtonFocused = false
                    DispatchQueue.main.async {
                        playButtonFocused = true
                    }
                } else if let ep = playItem {
                    // Scroll back to the episode row before the focus
                    // restore. tvOS's modal-dismiss restoration plus
                    // the nil-flicker focus transition below would
                    // otherwise leave the outer ScrollView pinned at
                    // the top, so the user landed on the right
                    // logical focus target but on a page that had
                    // scrolled away from it.
                    if let proxy = episodeRowScrollProxy {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("episodeRow", anchor: .top)
                        }
                    }
                    focusedEpisodeID = nil
                    DispatchQueue.main.async {
                        focusedEpisodeID = ep.id
                    }
                }
                playItem = nil
                playOriginatedFromPlayButton = false
            }
        }
        // AppRouter bumps this counter on every deep-link arrival so
        // a TopShelf tap on a different item can tear down the active
        // player session and let the new detail sheet surface cleanly.
        .onChange(of: appState.requestPlayerDismissal) { _, _ in
            if showPlayer { showPlayer = false }
        }
        .navigationDestination(item: $navigateToItem) { item in
            DetailRouterView(item: item)
        }
        .navigationDestination(item: $navigateToPerson) { route in
            PersonDetailView(personID: route.tmdbID, personName: route.name)
        }
        .navigationDestination(item: $navigateToSeerrRequest) { media in
            CatalogDetailView(media: media)
        }
        .onAppear {
            if viewModel == nil, let userID = appState.activeUser?.id {
                selectedEpisode = initialEpisode
                viewModel = DetailViewModel(
                    item: item,
                    itemService: dependencies.jellyfinItemService,
                    imageService: dependencies.jellyfinImageService,
                    userID: userID,
                    libraryService: dependencies.jellyfinLibraryService,
                    playbackService: dependencies.jellyfinPlaybackService,
                    initialEpisode: initialEpisode
                )
                Task {
                    await viewModel?.loadFullDetail()
                    updateBackdropURL()
                }
            }
        }
        .onChange(of: viewModel?.isLoading) { _, loading in
            updateBackdropURL()
            // Loading gate keeps the play button out of the view
            // tree at first paint, so the focus engine has nothing
            // to land on when it appears. Push focus explicitly
            // once isLoading flips false. Tiny defer rides out the
            // same focus-commit race other parts of the app dodge.
            if loading == false {
                deferOnMain(by: 0.1) {
                    playButtonFocused = true
                }
            }
        }
        .onChange(of: selectedEpisode?.id) { _, _ in updateBackdropURL() }
        .sheet(isPresented: $isPresentingDeleteSheet) {
            if let vm = viewModel {
                let popDetail = dismiss
                MediaDeletionSheet(
                    mode: .series(
                        itemID: vm.item.id,
                        tmdbID: vm.item.tmdbID,
                        title: vm.item.name,
                        seasons: deletionSeasonOptions(from: vm.seasons)
                    ),
                    onConfirm: { request in
                        do {
                            if request.deleteEntireSeries {
                                try await dependencies.mediaDeletionService.deleteSeries(
                                    itemID: vm.item.id,
                                    tmdbID: vm.item.tmdbID,
                                    cascadeToArrStack: request.cascadeToArrStack
                                )
                            } else {
                                try await dependencies.mediaDeletionService.deleteSeasons(
                                    seasonItemIDs: request.seasonItemIDs,
                                    cascadeToArrStack: false
                                )
                            }
                            // Drop the on-disk filter cache so the
                            // Library + Home rows don't keep showing
                            // the deleted item(s) until natural
                            // eviction. Active rows re-fetch on focus.
                            FilterCache.shared.clearAll()
                            // Tell Home to reload so the deleted series
                            // or season(s) drop out of its rows right away.
                            NotificationCenter.default.post(name: .homeItemDidDelete, object: nil)
                            // Only pop the detail view when the whole
                            // series was deleted. For seasons-only
                            // deletion the user might still want to
                            // view what's left.
                            if request.deleteEntireSeries {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(1100))
                                    popDetail()
                                }
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

    private func updateBackdropURL() {
        if let ep = selectedEpisode {
            backdropURL = dependencies.jellyfinImageService.episodeThumbnailURL(for: ep)
                ?? viewModel.flatMap { $0.backdropURL(for: $0.item) }
        } else {
            backdropURL = viewModel.flatMap { $0.backdropURL(for: $0.item) }
        }
    }

    // MARK: - Glass Panel

    private func glassPanel(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if isShowingEpisode {
                Text(vm.item.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(isShowingEpisode ? (selectedEpisode?.name ?? "") : vm.item.name)
                .font(.largeTitle)
                .fontWeight(.bold)
                .lineLimit(2)

            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 16) {
                    if isShowingEpisode, let ep = selectedEpisode {
                        HStack(spacing: 8) {
                            if let s = ep.parentIndexNumber {
                                Text("S\(s)")
                                    .fontWeight(.semibold)
                            }
                            if let e = ep.indexNumber {
                                Text("E\(e)")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                            if let runtime = ep.runTimeTicks {
                                Text("·").foregroundStyle(.tertiary)
                                Text(runtime.ticksToDisplay)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        ItemMetadataRow(item: vm.item, showRuntime: false) {
                            if let count = vm.item.childCount, count > 0 {
                                AnyView(Text("detail.seasonCount \(count)"))
                            } else {
                                AnyView(EmptyView())
                            }
                        }
                    }

                    // Genres are a series-level attribute, so they only
                    // belong on the series root. Showing them in the
                    // episode panel added one-to-two lines of variable
                    // height between episodes (the main driver of the
                    // inconsistent play-button position); the series root
                    // still shows them.
                    if !isShowingEpisode, let genres = vm.item.genres, !genres.isEmpty {
                        Text(genres.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        GlassActionButton(
                            title: playTitle(vm: vm),
                            systemImage: "play.fill",
                            isProminent: true,
                            subtitle: playButtonSubtitle(vm: vm),
                            progressFraction: playProgressFraction(vm: vm),
                            // Hold the button on a spinner until we've got
                            // a concrete play target. Avoids the visible
                            // "Abspielen" → "Fortsetzen + S1E5 · 12:34"
                            // repaint that fires when getNextUp lands a few
                            // hundred ms after the view appears.
                            isLoading: playTarget(vm: vm) == nil,
                            action: {
                                let ep = playTarget(vm: vm)
                                if let ep {
                                    playItem = ep
                                    playFromBeginning = false
                                    playOriginatedFromPlayButton = true
                                    showPlayer = true
                                }
                            }
                        )
                        .focused($playButtonFocused)

                        if !isShowingEpisode {
                            GlassActionButton(
                                title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
                                systemImage: vm.isFavorite ? "heart.fill" : "heart",
                                action: { Task { await vm.toggleFavorite() } }
                            )
                        }

                        if !isShowingEpisode {
                            GlassActionButton(
                                title: vm.isPlayed ? "detail.markUnwatched" : "detail.markWatched",
                                systemImage: vm.isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                                action: { Task { await vm.togglePlayed() } }
                            )
                        }

                        if isShowingEpisode {
                            GlassActionButton(
                                title: "detail.showSeries",
                                systemImage: "xmark",
                                action: {
                                    withAnimation { selectedEpisode = nil }
                                }
                            )
                        }

                        if isShowingEpisode, let ep = selectedEpisode {
                            GlassActionButton(
                                title: vm.isPlayed(ep) ? "detail.markUnwatched" : "detail.markWatched",
                                systemImage: vm.isPlayed(ep) ? "checkmark.circle.fill" : "checkmark.circle",
                                action: {
                                    let target = !vm.isPlayed(ep)
                                    Task { await vm.setEpisodePlayed(ep, isPlayed: target) }
                                }
                            )
                        }

                        if !isShowingEpisode,
                           appState.isSeerrConnected,
                           let tmdbID = vm.item.tmdbID,
                           shouldShowSeerrRequest(for: vm.item) {
                            GlassActionButton(
                                title: "detail.requestInSeerr",
                                systemImage: "tray.and.arrow.down",
                                action: {
                                    navigateToSeerrRequest = .stub(tmdbID: tmdbID, mediaType: .tv)
                                }
                            )
                        }

                        // Delete sits last in the row, matching MovieDetailView,
                        // so the destructive action is visually furthest from
                        // Play and any positive-action buttons.
                        if canDelete && !isShowingEpisode {
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

                // Series-level secondary info (tagline, crew, studios)
                // belongs on the series root, not the episode panel. Its
                // per-show height (a show with a tagline + crew makes the
                // card taller than one with only a studios line) was the
                // last driver of inconsistent episode-panel heights, which
                // shifted the description below it. The series root still
                // shows it.
                if !isShowingEpisode, DetailSecondaryInfo.hasContent(vm.item) {
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

    /// Single source of truth for "which episode does the play button
    /// act on right now?". Used by playTitle, playButtonSubtitle, the
    /// progress-bar fraction, AND the action closure so all four stay
    /// in lockstep.
    ///
    /// Resolution order:
    ///   1. Episode the user explicitly tapped (selectedEpisode)
    ///   2. Episode in the loaded list flagged as currentEpisodeID
    ///   3. The next-up item from getNextUp, populated as soon as
    ///      that response lands, so the button has data to render
    ///      before the full season episode list is fetched
    ///   4. First episode of the loaded list (fresh series start)
    private func playTarget(vm: DetailViewModel) -> JellyfinItem? {
        if let selectedEpisode { return selectedEpisode }
        if let id = vm.currentEpisodeID,
           let match = vm.episodes.first(where: { $0.id == id }) {
            return match
        }
        if let next = vm.nextUpEpisode { return next }
        return vm.episodes.first
    }

    private func playTitle(vm: DetailViewModel) -> LocalizedStringKey {
        if let ticks = playTarget(vm: vm)?.userData?.playbackPositionTicks,
           ticks > 0 {
            return "detail.resume"
        }
        return "detail.play"
    }

    /// Subtitle line next to the primary play button: shows which
    /// episode the tap will actually start (S1E5-style) plus, when
    /// the user is resuming, the timestamp it'll resume from.
    ///
    /// - "S1E5 · 12:34" when resuming a partially-watched episode
    /// - "S1E5" when starting fresh
    /// - nil if there's no resolvable target (e.g. an empty series)
    private func playButtonSubtitle(vm: DetailViewModel) -> String? {
        guard let target = playTarget(vm: vm) else { return nil }

        var parts: [String] = []
        let episodeLabel = episodeShorthand(for: target)
        if !episodeLabel.isEmpty {
            parts.append(episodeLabel)
        }
        if let ticks = target.userData?.playbackPositionTicks,
           ticks > 0,
           let stamp = ResumeTimeFormatter.format(ticks: ticks) {
            parts.append(stamp)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 0…1 fraction representing how far into the resolved target
    /// episode the user is. Returns nil when the episode is fresh or
    /// has no run-time metadata, the play button suppresses the
    /// progress overlay in those cases instead of drawing an empty
    /// bar.
    private func playProgressFraction(vm: DetailViewModel) -> Double? {
        guard let target = playTarget(vm: vm),
              let ticks = target.userData?.playbackPositionTicks, ticks > 0,
              let total = target.runTimeTicks, total > 0 else {
            return nil
        }
        return min(1.0, max(0.0, Double(ticks) / Double(total)))
    }

    /// "S1E5" / "S2E12" / "E5" / "" depending on which numbers the
    /// episode metadata carries. Keep verbatim so the label reads the
    /// same in every locale; the format is universal across streaming
    /// UIs.
    private func episodeShorthand(for episode: JellyfinItem) -> String {
        var out = ""
        if let s = episode.parentIndexNumber { out += "S\(s)" }
        if let e = episode.indexNumber { out += "E\(e)" }
        return out
    }

    /// The "Request in Seerr" button only makes sense for series that
    /// may still grow, a user with the full run of an ended show rarely
    /// wants to request it again. Jellyfin exposes this as the `status`
    /// field ("Continuing" vs "Ended"). Missing status → stay permissive
    /// and show the button rather than hiding a valid use case.
    private func shouldShowSeerrRequest(for item: JellyfinItem) -> Bool {
        guard let status = item.status else { return true }
        return status == "Continuing"
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

    // MARK: - Season Section

    private func seasonSection(vm: DetailViewModel) -> some View {
        // .focusSection keeps up/down moves within the season + episode
        // block. Without it, a far-right episode's up-swipe bypasses the
        // season bar entirely (no tab is geographically above it) and
        // lands on the overview textbox one section up. The section
        // modifier tells tvOS "prefer staying inside this region," so
        // the up-swipe falls onto a season tab instead, our
        // onMoveCommand redirect then snaps it to the selected one.
        VStack(alignment: .leading, spacing: 20) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(vm.seasons) { season in
                            SeasonTab(
                                id: season.id,
                                name: season.name,
                                isSelected: vm.selectedSeasonID == season.id,
                                focusedID: $focusedSeasonID,
                                action: {
                                    selectedEpisode = nil
                                    Task { await vm.loadEpisodes(seasonID: season.id) }
                                }
                            )
                            .id(season.id)
                            .contextMenu {
                                Button {
                                    let target = !vm.isPlayed(season)
                                    Task { await vm.setSeasonPlayed(seasonID: season.id, isPlayed: target) }
                                } label: {
                                    Label(
                                        vm.isPlayed(season) ? "detail.season.markUnwatched" : "detail.season.markWatched",
                                        systemImage: vm.isPlayed(season) ? "checkmark.circle.fill" : "checkmark.circle"
                                    )
                                }
                            }
                        }
                    }
                    // Focus scale is 1.05, without vertical slack the
                    // halo clips against the scroll-view top/bottom
                    // edges when a tab is focused.
                    .padding(.horizontal, 50)
                    .padding(.vertical, 12)
                }
                .onChange(of: focusedSeasonID) { oldID, newID in
                    // Three cases where we force focus back to the current
                    // season: first entry from above (oldID == nil), return
                    // from the episode row below (episodesHadFocus), or a
                    // fall-through from some other section.
                    let cameFromOutside = oldID == nil || episodesHadFocus
                    if cameFromOutside, let newID, newID != vm.selectedSeasonID {
                        let target = vm.selectedSeasonID
                        // Defer to the next runloop tick, setting
                        // @FocusState synchronously inside its own onChange
                        // gets silently dropped on tvOS. DispatchQueue.main
                        // is the one that's reliably honored here; Task or
                        // Task.sleep hops both land in the wrong cycle and
                        // get swallowed.
                        DispatchQueue.main.async {
                            focusedSeasonID = target
                        }
                    }
                    episodesHadFocus = false
                    if newID != nil {
                        lastFocusedArea = .season
                    }
                    if let focusedID = focusedSeasonID {
                        withAnimation { proxy.scrollTo(focusedID, anchor: .center) }
                    }
                    if newID != nil {
                        episodeRedirectDone = false
                    }
                }
                .onChange(of: focusedEpisodeID) { _, newEpisode in
                    if newEpisode != nil {
                        episodesHadFocus = true
                        lastFocusedArea = .episode
                    }
                }
                .onChange(of: vm.selectedSeasonID) { _, newID in
                    episodeRedirectDone = false
                    withAnimation { proxy.scrollTo(newID, anchor: .center) }
                }
            }

            // Invisible focus bridge between the season bar and the
            // episode row. Spans the full width (same as the episode
            // row) so an up-swipe from a far-right episode, where
            // the actual season tabs don't line up geographically,
            // lands here *before* tvOS's picker continues upward into
            // the overview textbox or the tech-info cards. Once
            // focused, the bridge redirects based on which row the
            // user came from; the target tab / episode gets focus on
            // the next SwiftUI cycle.
            //
            // Height: 24pt. The geographic focus picker on tvOS picks
            // by *proximity*, but it also weights frame size when
            // proximity ties, sub-10pt focusables get skipped if
            // there's a much larger one nearby. 1pt missed often,
            // 8pt was better but still flaky on a fast season-tab →
            // down sequence. 24pt is reliably picked up. Color.clear
            // means it's still invisible on screen.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .focusable()
                .focused($focusBridgeActive)
                .onChange(of: focusBridgeActive) { _, active in
                    guard active else { return }
                    // FocusState writes still need a defer past the
                    // SwiftUI tick currently committing the bridge's
                    // own focus, otherwise tvOS swallows them, so
                    // the season case (which writes a FocusState)
                    // keeps a small delay. The episode case writes
                    // a plain @State variable (pendingEpisodeFocus)
                    // that the ScrollViewReader observes; that's
                    // not subject to the FocusState race, so we
                    // can fire it immediately and shave off the
                    // 30 ms latency the user perceived as "fast
                    // press needs two clicks".
                    let deferFocusWrite = { (work: @escaping () -> Void) in
                        deferOnMain(by: 0.03, work)
                    }
                    switch lastFocusedArea {
                    case .episode:
                        let target = vm.selectedSeasonID
                        deferFocusWrite { focusedSeasonID = target }
                    case .season:
                        let target: String? = {
                            if let current = vm.currentEpisodeID,
                               vm.episodes.contains(where: { $0.id == current }) {
                                return current
                            }
                            return vm.episodes.first?.id
                        }()
                        if let target {
                            // Immediate, pendingEpisodeFocus is plain
                            // @State, not FocusState. The receiver in
                            // the episode-row ScrollViewReader scrolls
                            // the target into the LazyHStack viewport,
                            // then writes focusedEpisodeID with its
                            // own short post-scroll defer.
                            pendingEpisodeFocus = target
                        }
                    case .none:
                        // First time anything inside this section
                        // gets focus (e.g. NavigationStack push).
                        // Send focus to the selected season as a
                        // sensible default, user can press down to
                        // reach the episodes from there.
                        let target = vm.selectedSeasonID
                        deferFocusWrite { focusedSeasonID = target }
                    }
                }

            if !vm.episodes.isEmpty {
                ScrollViewReader { episodeProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 24) {
                            ForEach(vm.episodes) { episode in
                                Button {
                                    playItem = episode
                                    playFromBeginning = false
                                    playOriginatedFromPlayButton = false
                                    showPlayer = true
                                } label: {
                                    EpisodeLandscapeCard(
                                        episode: episode,
                                        imageURL: dependencies.jellyfinImageService.episodeThumbnailURL(for: episode),
                                        isSelected: selectedEpisode?.id == episode.id,
                                        isCurrent: vm.currentEpisodeID == episode.id,
                                        isFocused: focusedEpisodeID == episode.id,
                                        isPlayed: vm.isPlayed(episode)
                                    )
                                }
                                .buttonStyle(EpisodeCardButtonStyle())
                                .focused($focusedEpisodeID, equals: episode.id)
                                // Prime the season-bar target *before* the
                                // move resolves. Without this, swiping up
                                // from a far-right episode (outside the
                                // horizontal span of the season tabs) lets
                                // tvOS's geographic picker skip the bar
                                // entirely and land on the TechInfoBox /
                                // overview textbox above. Writing
                                // focusedSeasonID synchronously here puts
                                // an explicit focus target on the table
                                // when the engine resolves the up-move.
                                .onMoveCommand { direction in
                                    if direction == .up {
                                        focusedSeasonID = vm.selectedSeasonID
                                    }
                                }
                                .id(episode.id)
                                .contextMenu {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            selectedEpisode = episode
                                        }
                                        // The context menu restores focus to this
                                        // episode card on dismiss. Flag it so the
                                        // focusedEpisodeID observer bounces focus up
                                        // to the play button the moment focus lands
                                        // back on the row (a fixed delay lost the
                                        // race against the menu's restore). The
                                        // delayed write is a fallback for the case
                                        // where focus never visibly cycles.
                                        pendingPlayFocusAfterMenu = true
                                        deferOnMain(by: 0.6) {
                                            guard pendingPlayFocusAfterMenu else { return }
                                            pendingPlayFocusAfterMenu = false
                                            playButtonFocused = false
                                            DispatchQueue.main.async { playButtonFocused = true }
                                        }
                                    } label: {
                                        Label("detail.episode.showDetails", systemImage: "info.circle")
                                    }

                                    Button {
                                        playItem = episode
                                        playFromBeginning = true
                                        playOriginatedFromPlayButton = false
                                        showPlayer = true
                                    } label: {
                                        Label("detail.play", systemImage: "play.fill")
                                    }

                                    if let ticks = episode.userData?.playbackPositionTicks, ticks > 0 {
                                        Button {
                                            playItem = episode
                                            playFromBeginning = false
                                            playOriginatedFromPlayButton = false
                                            showPlayer = true
                                        } label: {
                                            Label("detail.resume", systemImage: "play.circle")
                                        }
                                    }

                                    Button {
                                        let target = !vm.isPlayed(episode)
                                        Task { await vm.setEpisodePlayed(episode, isPlayed: target) }
                                    } label: {
                                        Label(
                                            vm.isPlayed(episode) ? "detail.markUnwatched" : "detail.markWatched",
                                            systemImage: vm.isPlayed(episode) ? "checkmark.circle.fill" : "checkmark.circle"
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 50)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: vm.selectedSeasonID) { _, _ in
                        if let first = vm.episodes.first {
                            episodeProxy.scrollTo(first.id, anchor: .leading)
                        }
                        deferOnMain(by: 0.15) {
                            scrollToCurrentEpisode(proxy: episodeProxy, vm: vm)
                        }
                    }
                    .onChange(of: focusedEpisodeID) { _, newID in
                        // "Show Details" was chosen from the context menu and
                        // focus has just been restored to the row. Bounce it up
                        // to the play button instead. Two-step write forces a
                        // real focus transition (a same-value write is a no-op).
                        if pendingPlayFocusAfterMenu, newID != nil {
                            pendingPlayFocusAfterMenu = false
                            playButtonFocused = false
                            DispatchQueue.main.async { playButtonFocused = true }
                            return
                        }
                        if newID != nil && !episodeRedirectDone {
                            episodeRedirectDone = true
                            if let currentID = vm.currentEpisodeID,
                               newID != currentID,
                               vm.episodes.contains(where: { $0.id == currentID }) {
                                focusedEpisodeID = currentID
                            }
                        }
                    }
                    .onChange(of: pendingEpisodeFocus) { _, target in
                        guard let target else { return }
                        // Scroll the target into the LazyHStack
                        // viewport so its .focused modifier exists
                        // when we write focusedEpisodeID. Without
                        // the scroll, the write silently failed for
                        // a card that had been scrolled out of the
                        // rendered window, that was the right-side
                        // 2-press case.
                        withAnimation(.easeInOut(duration: 0.2)) {
                            episodeProxy.scrollTo(target, anchor: .center)
                        }
                        deferOnMain {
                            focusedEpisodeID = target
                            pendingEpisodeFocus = nil
                        }
                    }
                    .onAppear {
                        scrollToCurrentEpisode(proxy: episodeProxy, vm: vm)
                    }
                }
            }
        }
        .focusSection()
    }

    private func scrollToCurrentEpisode(proxy: ScrollViewProxy, vm: DetailViewModel) {
        guard let currentID = vm.currentEpisodeID,
              vm.episodes.contains(where: { $0.id == currentID }) else { return }
        deferOnMain(by: 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }
}

// MARK: - Season Tab

struct SeasonTab: View {
    let id: String
    let name: String
    let isSelected: Bool
    var focusedID: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focusedID.wrappedValue == id }

    var body: some View {
        Button { action() } label: {
            Text(name)
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(tabBackground)
                )
        }
        .buttonStyle(SeasonTabButtonStyle())
        .focused(focusedID, equals: id)
    }

    private var tabBackground: Color {
        if isFocused { return .white.opacity(0.12) }
        if isSelected { return .white.opacity(0.08) }
        return .clear
    }
}

// MARK: - Button Styles

struct EpisodeCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Stroke is drawn inside EpisodeLandscapeCard so it hugs the
        // thumbnail only, not the title/runtime row below.
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

struct SeasonTabButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Asymmetric animation on the stroke: 50 ms delay on fade-in,
        // zero delay on fade-out. If any residual wrong-tab-first
        // transition slips past the onMoveCommand prime (first entry
        // into the view, an edge-case direction), the stroke simply
        // never becomes visible on the wrong tab, the 50 ms window
        // is enough for the DispatchQueue fallback to land focus on
        // the right tab first. Between-tab navigation still feels
        // instant because 50 ms is sub-perceptual.
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
                    .animation(
                        isFocused
                            ? .easeIn(duration: 0.15).delay(0.05)
                            : .easeOut(duration: 0.1),
                        value: isFocused
                    )
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Episode Landscape Card

struct EpisodeLandscapeCard: View {
    let episode: JellyfinItem
    let imageURL: URL?
    var isSelected: Bool = false
    var isCurrent: Bool = false

    /// Set by the caller based on the surrounding `@FocusState`
    /// (`focusedEpisodeID == episode.id`). Drives the accent-colored
    /// focus stroke on the thumbnail, `@Environment(\.isFocused)` in
    /// a Button label is unreliable on tvOS, so we pass it explicitly.
    var isFocused: Bool = false

    /// Played state passed explicitly by the caller so the badge can
    /// live-update from the view model's override map (the immutable
    /// `episode.userData` snapshot would never change in-session).
    var isPlayed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                AsyncCachedImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.Theme.surface)
                        .overlay(
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 30))
                                .foregroundStyle(.tertiary)
                        )
                }
                .frame(width: 360, height: 202)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    // Outer stroke, same pattern as MediaCard. Keeps
                    // the thumbnail itself clean (no inner bite) and
                    // leaves the 4pt progress bar fully visible.
                    RoundedRectangle(cornerRadius: 12 + strokeWidth)
                        .strokeBorder(strokeStyle, lineWidth: strokeWidth)
                        .padding(-strokeWidth)
                        .animation(.easeInOut(duration: 0.2), value: isFocused)
                )

                if let pct = episode.userData?.playedPercentage, pct > 0 {
                    GeometryReader { geo in
                        VStack {
                            Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.ultraThinMaterial).frame(height: 6)
                                Rectangle().fill(Color.white.opacity(0.9)).frame(width: geo.size.width * pct / 100, height: 6)
                            }
                        }
                    }
                    .frame(width: 360, height: 202)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: 360, height: 202)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let ep = episode.indexNumber {
                        Text("E\(ep)")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .fontWeight(.semibold)
                    }
                    Text(episode.name)
                        .font(.caption)
                        .lineLimit(1)
                }

                if let runtime = episode.runTimeTicks {
                    Text(runtime.ticksToDisplay)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 360, alignment: .leading)
        }
    }

    /// Focus stroke beats selected and current, when the user is
    /// interacting with the card, that trumps whatever state it's in.
    /// AnyShapeStyle lets us mix the tint ShapeStyle (focus) with plain
    /// Color values (selected/current) behind the same .strokeBorder.
    private var strokeStyle: AnyShapeStyle {
        if isFocused { return AnyShapeStyle(TintShapeStyle.tint) }
        if isSelected { return AnyShapeStyle(TintShapeStyle.tint.opacity(0.8)) }
        if isCurrent { return AnyShapeStyle(Color.green.opacity(0.8)) }
        return AnyShapeStyle(Color.clear)
    }

    private var strokeWidth: CGFloat {
        if isFocused { return 3 }
        return isCurrent ? 3 : 2
    }
}
