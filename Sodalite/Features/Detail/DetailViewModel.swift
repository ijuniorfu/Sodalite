import Foundation
import Observation

@Observable
final class DetailViewModel {
    var item: JellyfinItem
    var isFavorite: Bool
    var isPlayed: Bool
    /// Per-item played overrides keyed by item / episode / season ID.
    /// Lets the cards live-update their watched badge without mutating
    /// the immutable JellyfinItem structs (same "pass state explicitly
    /// to the card" pattern as isFocused / isCurrent).
    var playedOverrides: [String: Bool] = [:]
    var seasons: [JellyfinItem] = []
    var episodes: [JellyfinItem] = []
    /// True while a cache-miss episode fetch for the selected season is
    /// in flight. Drives the skeleton placeholder row so the section
    /// paints instantly instead of staying blank until the round-trip
    /// lands (the "grey then everything at once" slow-CDN symptom).
    var isLoadingEpisodes = false
    /// True while the season list itself is still loading (before any season
    /// tab exists). Drives a skeleton season bar + episode row so the whole
    /// section's structure paints at the snapshot deadline instead of being
    /// a blank gap until getSeasons lands on a slow CDN.
    var isLoadingSeasons = false
    var collectionItems: [JellyfinItem] = []
    var currentEpisodeID: String?
    /// The full next-up episode item, populated as soon as the
    /// `getNextUp` response lands. Used by the play button to render
    /// "S1E5 · 12:34" + the resume-progress bar before the season's
    /// full episode list has finished loading. Without this the
    /// button stays on its initial "Play" / no-subtitle state for the
    /// few hundred ms it takes loadEpisodes to fill `episodes`, which
    /// reads as a layout flicker on the user's first focused tile.
    var nextUpEpisode: JellyfinItem?
    var similarItems: [JellyfinItem] = []
    var selectedSeasonID: String?
    var isLoading = false
    /// Flips true once the full-detail fetch has settled (success or
    /// failure). The snapshot-paint deadline can flip `isLoading`
    /// false while the detail roundtrip is still in flight on slow
    /// servers; the views key placeholder boxes for overview /
    /// secondary info on this so those sections reserve their space
    /// instead of popping in and shifting the layout (Sodalite#15).
    var hasFullDetail = false
    var cachedPlaybackInfo: PlaybackInfoResponse?

    /// True when the server reported at least one local trailer for
    /// this item. Drives the detail-view Trailer button's visibility.
    var hasLocalTrailer: Bool {
        (item.localTrailerCount ?? 0) > 0
    }

    private let itemService: JellyfinItemServiceProtocol
    private let libraryService: JellyfinLibraryServiceProtocol?
    private let playbackService: JellyfinPlaybackServiceProtocol?
    private let imageService: JellyfinImageService
    private let userID: String
    /// When the detail was opened from a specific episode (vs. the
    /// series tile), this is that episode. `loadSeasons` lands on its
    /// season and selects it instead of running the next-up logic.
    private let initialEpisode: JellyfinItem?
    /// In-flight prefetch task, cancelled on deinit so a disappearing
    /// view doesn't keep self alive waiting on network. Plain stored
    /// property: the `isolated deinit` below runs on MainActor, so no
    /// isolation escape hatch is needed for the cancel anymore.
    private var prefetchTask: Task<Void, Never>?
    /// Separate slot for the PlaybackInfo prefetch. It used to share
    /// `prefetchTask` with the season warming, and since loadSeasons
    /// schedules startSeasonPrefetch right after prefetchPlaybackInfo
    /// on every multi-season series, the season pass cancelled the
    /// PlaybackInfo fetch ~immediately: cachedPlaybackInfo stayed nil
    /// and the play button paid the full round trip it was meant to
    /// hide.
    private var playbackInfoPrefetchTask: Task<Void, Never>?

    /// Per-season episode cache. Hit on `loadEpisodes(seasonID:)` so a
    /// season tab the user has already (or pre-emptively) visited
    /// switches in instantly instead of doing another round trip.
    private var episodesCache: [String: [JellyfinItem]] = [:]

    /// Per-episode full-detail cache. The episode list is fetched with a
    /// slim field set (no MediaStreams / MediaSources), so when an episode
    /// is opened into episode mode we fetch its full detail once and cache
    /// it here for the TechInfoBox.
    private var episodeDetailCache: [String: JellyfinItem] = [:]

    isolated deinit {
        prefetchTask?.cancel()
        playbackInfoPrefetchTask?.cancel()
    }

    init(
        item: JellyfinItem,
        itemService: JellyfinItemServiceProtocol,
        imageService: JellyfinImageService,
        userID: String,
        libraryService: JellyfinLibraryServiceProtocol? = nil,
        playbackService: JellyfinPlaybackServiceProtocol? = nil,
        initialEpisode: JellyfinItem? = nil
    ) {
        self.item = item
        self.isFavorite = item.userData?.isFavorite ?? false
        self.isPlayed = item.userData?.played ?? false
        self.itemService = itemService
        self.libraryService = libraryService
        self.playbackService = playbackService
        self.imageService = imageService
        self.userID = userID
        self.initialEpisode = initialEpisode
    }

    /// Fetches the item's local trailers and returns the first one to
    /// play, or nil if there are none or the request fails. Called on
    /// Trailer-button tap so we only hit the endpoint on demand.
    func loadTrailer() async -> JellyfinItem? {
        let trailers = try? await itemService.getLocalTrailers(userID: userID, itemID: item.id)
        return trailers?.first
    }

    func loadFullDetail() async {
        // Episode deep-links arrive with the full episode already in hand
        // (the deep-link resolver fetched it) plus the series name in the
        // stub, which is enough to paint the hero panel, play button,
        // overview and tech box on the first frame. Skip the loading gate
        // in that case so they paint immediately and seasons / cast /
        // similar fade in as they land, instead of holding everything
        // behind the spinner until the series detail + seasons round-trips
        // finish (the "grey for a few seconds then everything at once" the
        // episode path showed on slow CDNs). Safe from the play-button
        // repaint storm the series path guards against: the target episode
        // is already known, so no next-up resolution runs here.
        isLoading = (initialEpisode == nil)

        let itemID = item.id
        let itemType = item.type

        // Fetch detail. We avoid `async let` here because it
        // interacts badly with @MainActor-isolated service calls crossing
        // back into a non-isolated @Observable class, the task-local
        // allocator ends up deallocating a pointer that is no longer the
        // top of its stack and we crash with
        // swift_task_dealloc_specific SIGABRT "freed pointer was not the
        // last allocation" in asyncLet_finish_after_task_completion.
        // A detached-ish Task{}.value pair stays parallel but keeps each
        // call on its own independent allocator.
        let detailTask = Task { try? await itemService.getItemDetail(userID: userID, itemID: itemID) }

        // Series content (seasons + next-up + episodes) only depends
        // on the item ID, which we already have from the passed-in
        // item, start the chain in parallel with the detail fetch
        // so the play button's "Fortsetzen + S1E5 · 12:34" subtitle
        // and progress overlay arrive on the screen at the same
        // moment as the rest of the detail panel.
        let seriesContentTask: Task<Void, Never>? = (itemType == .series) ? Task {
            await loadSeasons()
        } : nil
        let collectionContentTask: Task<Void, Never>? = (itemType == .boxSet) ? Task {
            await loadCollectionItems()
        } : nil
        let playlistContentTask: Task<Void, Never>? = (itemType == .playlist) ? Task {
            await loadPlaylistItems()
        } : nil

        // Similar items power a row near the bottom of the detail
        // screen, well below the fold on every reasonable viewport,
        // so the user wouldn't see it within the first paint anyway.
        // Fire it without awaiting so it doesn't gate isLoading
        // flipping false; the similar-row appears progressively when
        // the response lands.
        Task { [weak self] in
            guard let self else { return }
            if let similar = try? await itemService.getSimilarItems(itemID: itemID, userID: userID, limit: 12) {
                await MainActor.run { self.similarItems = similar.items }
            }
        }

        // Snapshot-paint deadline. If the detail / seasons / collection
        // fetches haven't all settled within this budget, flip
        // isLoading=false and paint from the JellyfinItem snapshot
        // we already have in hand from the navigating row. Fast
        // servers (homelab Jellyfin, sub-300 ms detail) still hit
        // the original quiet single-render path because they complete
        // before the deadline fires. Slow servers (CDN-backed libraries
        // that take 10+ s for a detail roundtrip, per Sodalite#12)
        // stop showing the 30 s spinner; the hero region paints from
        // the snapshot immediately and overview / cast / seasons /
        // episodes fade in as their fetches settle. Accepted tradeoff:
        // a brief field-fill repaint on slow servers, vs. the
        // 30-second hard wall before.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.isLoading else { return }
            self.isLoading = false
        }

        if let detail = await detailTask.value {
            item = detail
            isFavorite = detail.userData?.isFavorite ?? false
            isPlayed = detail.userData?.played ?? false
        }
        // Settled either way: on failure nothing more will arrive, so
        // the placeholder boxes must stop reserving space.
        hasFullDetail = true

        if itemType != .series && itemType != .boxSet && itemType != .playlist {
            prefetchPlaybackInfo(for: itemID)
        }

        // Wait for the parallel chains to finish so isLoading flips
        // false at the latest once every section has its data. On
        // fast servers this fires before the deadline above; on slow
        // servers the deadline already flipped it false and this is
        // a no-op.
        await seriesContentTask?.value
        await collectionContentTask?.value
        await playlistContentTask?.value

        isLoading = false
    }

    func loadSeasons() async {
        guard item.type == .series else { return }

        // Skeleton the season bar while getSeasons is in flight. Cleared on
        // exit, by which point `seasons` is populated and the real bar takes
        // over (the view shows the real section whenever seasons is
        // non-empty, so the exact flip moment can't leave a skeleton over
        // real content).
        isLoadingSeasons = true
        defer { isLoadingSeasons = false }

        // Three independent fetches all keyed off the series ID:
        //   - getSeasons:  the season-tabs list
        //   - getNextUp:   the resume target (if any)
        //   - loadEpisodes: needs a season ID, but next-up gives us
        //                  one as soon as it lands, so we wait
        //                  ONLY on next-up before kicking that off,
        //                  not on the seasons response.
        let seasonsTask = Task { try? await itemService.getSeasons(seriesID: item.id, userID: userID) }

        // Opened from a specific episode: land on that episode's season
        // and select it, skipping the next-up-driven selection entirely.
        // The view sets selectedEpisode = initialEpisode for the panel.
        if let initialEpisode, let seasonID = initialEpisode.seasonId {
            selectedSeasonID = seasonID
            await loadEpisodes(seasonID: seasonID)
            currentEpisodeID = initialEpisode.id
            prefetchPlaybackInfo(for: initialEpisode.id)
            if let seasonsResponse = await seasonsTask.value {
                seasons = seasonsResponse.items
            }
            startSeasonPrefetch()
            return
        }

        let nextUpTask: Task<JellyfinItemsResponse?, Never>? = libraryService.map { libService in
            Task { try? await libService.getNextUp(userID: userID, seriesID: item.id, limit: 1) }
        }

        // As soon as next-up resolves: publish nextUpEpisode + fire
        // loadEpisodes for that episode's season in parallel with
        // the still-pending getSeasons. Without this, loadEpisodes
        // would only start AFTER seasons had returned and we'd
        // serialise three round-trips into the critical path
        // instead of overlapping them.
        let earlyEpisodesTask: Task<Void, Never>? = nextUpTask.map { task in
            Task { @MainActor [weak self] in
                guard let self,
                      let nextEp = await task.value?.items.first else { return }
                self.nextUpEpisode = nextEp
                if let seasonID = nextEp.seasonId {
                    self.selectedSeasonID = seasonID
                    await self.loadEpisodes(seasonID: seasonID)
                    self.currentEpisodeID = nextEp.id
                    self.prefetchPlaybackInfo(for: nextEp.id)
                }
            }
        }

        // Wait on the seasons response, fast network races aside
        // this is the slowest of the three calls because Jellyfin
        // returns full metadata for every season image tag.
        let seasonsResponse = await seasonsTask.value
        if let seasonsResponse {
            seasons = seasonsResponse.items
        }

        // Let the early-episodes task settle (probably already done)
        // before falling back to the no-next-up path.
        await earlyEpisodesTask?.value

        // Fallback path: no next-up means no watch history. Land on
        // season 1 with its episode list loaded so the user has
        // something to focus into.
        if nextUpEpisode == nil, episodes.isEmpty,
           let firstSeasonID = seasons.first?.id {
            selectedSeasonID = firstSeasonID
            await loadEpisodes(seasonID: firstSeasonID)
            if let firstEp = episodes.first?.id {
                prefetchPlaybackInfo(for: firstEp)
            }
        }

        startSeasonPrefetch()
    }

    /// Re-fetch the season list after a mutation (the user deleted one or
    /// more seasons from the deletion sheet). Unlike `loadSeasons()`, this
    /// doesn't re-run next-up / initial-episode selection, it keeps the user
    /// where they are: if the currently selected season survived the deletion
    /// it stays selected with a fresh episode list, otherwise we fall back to
    /// the first remaining season. The per-season episode cache is dropped
    /// wholesale because deleted seasons leave stale entries behind.
    func refreshSeasons() async {
        guard item.type == .series else { return }

        episodesCache.removeAll()

        guard let response = try? await itemService.getSeasons(seriesID: item.id, userID: userID) else {
            return
        }
        seasons = response.items

        // The selected season may have just been deleted. Keep it if it
        // survived, otherwise land on the first remaining season.
        let survivingSelection = selectedSeasonID.flatMap { id in
            seasons.first(where: { $0.id == id })?.id
        }
        if let seasonID = survivingSelection ?? seasons.first?.id {
            await loadEpisodes(seasonID: seasonID)
        } else {
            // Every season was deleted: nothing left to show.
            selectedSeasonID = nil
            episodes = []
        }
    }

    /// Re-fetch the resume position after playback ends so the Play
    /// button shows where the user actually stopped, not the spot they
    /// resumed from at launch (issue #24). Driven by
    /// `.playbackProgressDidChange`, which the player posts once Jellyfin
    /// has confirmed the PlaybackStopped position, so this always reads
    /// the updated value rather than racing the fire-and-forget report.
    ///
    /// Deliberately lighter than loadFullDetail(): it refreshes only the
    /// userData that feeds the resume label + relaunch position and never
    /// touches `isLoading`, so returning from the player doesn't reflash
    /// the detail spinner.
    func refreshResumePosition() async {
        // Every observed-state assignment below is hopped onto the
        // MainActor explicitly. This method runs without isLoading (by
        // design, so returning from the player doesn't reflash the detail
        // spinner), which means the @Observable mutation is the ONLY
        // re-render trigger. DetailViewModel is a non-isolated @Observable
        // class, so the continuation after a @MainActor service await
        // resumes on the cooperative executor, not main; an off-main
        // @Observable mutation does not reliably invalidate the SwiftUI
        // view. loadFullDetail() gets away with the same off-main `item =`
        // only because it also flips isLoading on settle, forcing a render.
        // Here there is no such flip, so without MainActor.run the model
        // updated (relaunch resumed from the right spot) but the Play
        // button's timestamp + progress overlay stayed stale (issue #24
        // follow-up). Mirrors the similarItems MainActor.run in loadFullDetail.
        switch item.type {
        case .series:
            // The series play button resumes the next-up / current
            // episode, so the position lives on the EPISODE's userData,
            // not the series'. Refresh next-up, the on-screen season's
            // episode list, and drop the per-episode detail cache so an
            // open episode panel re-enriches from fresh data.
            let nextUp = try? await libraryService?.getNextUp(userID: userID, seriesID: item.id, limit: 1)
            let seasonEpisodes: (seasonID: String, items: [JellyfinItem])?
            if let seasonID = selectedSeasonID,
               let response = try? await itemService.getEpisodes(seriesID: item.id, seasonID: seasonID, userID: userID) {
                seasonEpisodes = (seasonID, response.items)
            } else {
                seasonEpisodes = nil
            }
            await MainActor.run {
                episodeDetailCache.removeAll()
                if let next = nextUp?.items.first {
                    nextUpEpisode = next
                    currentEpisodeID = next.id
                }
                if let seasonEpisodes {
                    episodesCache[seasonEpisodes.seasonID] = seasonEpisodes.items
                    episodes = seasonEpisodes.items
                }
            }
        default:
            if let detail = try? await itemService.getItemDetail(userID: userID, itemID: item.id) {
                await MainActor.run {
                    item = detail
                    isFavorite = detail.userData?.isFavorite ?? false
                    isPlayed = detail.userData?.played ?? false
                }
            }
        }
    }

    /// Authoritatively patch the in-memory resume position for `itemID`
    /// straight from the playback-stop payload (issue #24).
    ///
    /// This is the deterministic counterpart to refreshResumePosition():
    /// the player already knows exactly which item stopped and where, so
    /// we patch userData.playbackPositionTicks on every in-memory copy of
    /// that item rather than re-fetching and racing the server's commit /
    /// the ETag cache (the re-fetch path left the movie button stale ~10%
    /// of the time and the episode button stale every time). The id may
    /// match the movie itself, the series' next-up / current episode, an
    /// episode in the loaded list, or a cached episode, so patch them all.
    ///
    /// Must run on the MainActor (callers are SwiftUI .onReceive
    /// closures): synchronous and main-isolated so the @Observable
    /// mutation reliably re-renders the Play button.
    @MainActor
    func applyPlaybackPosition(itemID: String, ticks: Int64) {
        func patch(_ candidate: inout JellyfinItem) {
            guard candidate.id == itemID else { return }
            candidate.setResumePosition(ticks)
        }
        patch(&item)
        if var next = nextUpEpisode { patch(&next); nextUpEpisode = next }
        for index in episodes.indices { patch(&episodes[index]) }
        for index in collectionItems.indices { patch(&collectionItems[index]) }
        for (key, var list) in episodesCache {
            for index in list.indices { patch(&list[index]) }
            episodesCache[key] = list
        }
        if var cached = episodeDetailCache[itemID] {
            patch(&cached)
            episodeDetailCache[itemID] = cached
        }
    }

    func loadEpisodes(seasonID: String) async {
        selectedSeasonID = seasonID

        if let cached = episodesCache[seasonID] {
            episodes = cached
            isLoadingEpisodes = false
            // Keep warming the rest, re-anchored on the season now on
            // screen so the next-likely tabs come first.
            startSeasonPrefetch()
            return
        }

        // Cache miss: this is a season the user is waiting on right now.
        // Cancel the background season prefetch first so it isn't holding
        // HTTPClient request slots this foreground fetch needs. Prefetch
        // hogging the request budget was the "switching to season 2 takes
        // forever while it prefetches every other season" regression.
        prefetchTask?.cancel()

        // Drop the prior season's list and show skeletons for the target
        // season rather than the wrong season's episodes under the newly
        // selected tab.
        episodes = []
        isLoadingEpisodes = true

        do {
            let response = try await itemService.getEpisodes(seriesID: item.id, seasonID: seasonID, userID: userID)
            episodesCache[seasonID] = response.items
            // A newer season selection may have superseded this fetch
            // while it was in flight (fast tab-mashing). Keep the result
            // in the cache but don't clobber the season now on screen, and
            // let the superseding call own the prefetch restart.
            guard selectedSeasonID == seasonID else { return }
            episodes = response.items
            isLoadingEpisodes = false
        } catch {
            guard selectedSeasonID == seasonID else { return }
            isLoadingEpisodes = false
        }

        // Foreground fetch is done, resume warming the remaining seasons in
        // the background, nearest to the one now on screen first.
        startSeasonPrefetch()
    }

    /// (Re)start the background season prefetch, cancelling any prior run.
    /// Called after the foreground season settles so prefetch always trails
    /// the user (warming the seasons nearest the one on screen) instead of
    /// racing ahead and hogging the request budget.
    private func startSeasonPrefetch() {
        guard item.type == .series, seasons.count > 1 else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in await self?.prefetchRemainingSeasons() }
    }

    /// Warm the per-season episode cache for the seasons the user has not
    /// opened yet, so later season switches are instant cache hits.
    ///
    /// Two deliberate properties, both learned from the regression where
    /// blanket prefetch starved the user-driven season switch on slow CDNs:
    ///
    /// 1. Nearest-first. Seasons are warmed in order of distance from the
    ///    one on screen, so an adjacent tab (the likely next pick) is ready
    ///    before season 10 is.
    /// 2. Sequential and cancellable. One in-flight prefetch request at a
    ///    time leaves the rest of the HTTPClient budget free for whatever
    ///    the user does next, and a cancel (they switched seasons) lands
    ///    after at most one request instead of after a whole fan-out batch.
    func prefetchRemainingSeasons() async {
        guard item.type == .series else { return }

        // Yield the network to the foreground first-paint fetch before
        // warming anything.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }

        let seriesID = item.id
        let uid = userID
        let service = itemService

        let order = seasons.map(\.id)
        let anchor = selectedSeasonID.flatMap { order.firstIndex(of: $0) } ?? 0
        let pending = order.enumerated()
            .filter { episodesCache[$0.element] == nil }
            .sorted { abs($0.offset - anchor) < abs($1.offset - anchor) }
            .map(\.element)

        for seasonID in pending {
            if Task.isCancelled { return }
            // A foreground switch may have cached this season meanwhile.
            guard episodesCache[seasonID] == nil else { continue }
            guard let response = try? await service.getEpisodes(seriesID: seriesID, seasonID: seasonID, userID: uid) else { continue }
            if Task.isCancelled { return }
            episodesCache[seasonID] = response.items
        }
    }

    /// Full episode detail (MediaStreams / MediaSources) for an episode the
    /// user opened into episode mode. The list itself is fetched slim, so
    /// the TechInfoBox needs this on-demand fetch. Cached per episode and
    /// falls back to the slim list item if the detail fetch fails.
    func enrichedEpisode(for episode: JellyfinItem) async -> JellyfinItem {
        if let cached = episodeDetailCache[episode.id] { return cached }
        guard let detail = try? await itemService.getItemDetail(userID: userID, itemID: episode.id) else {
            return episode
        }
        episodeDetailCache[episode.id] = detail
        return detail
    }

    func loadCollectionItems() async {
        guard item.type == .boxSet else { return }

        do {
            // Chronological: oldest first. Franchise box-sets (Iron
            // Man → Avengers, Harry Potter 1 → 8) read naturally
            // left-to-right in release order, SortName would give
            // "Avengers" before "Iron Man" and defeat the point of a
            // collection. PremiereDate is the original theatrical /
            // first-air date Jellyfin stamps on each item.
            let query = ItemQuery(
                parentID: item.id,
                sortBy: "PremiereDate,ProductionYear,SortName",
                sortOrder: "Ascending",
                limit: 50
            )
            let response = try await itemService.getCollectionItems(userID: userID, query: query)
            collectionItems = response.items
        } catch {
        }
    }

    func loadPlaylistItems() async {
        guard item.type == .playlist else { return }

        do {
            // No sortBy: the server returns playlist members in the
            // user's manual playlist order. Sorting (as collections do by
            // PremiereDate) would defeat the purpose of a playlist.
            let query = ItemQuery(parentID: item.id, limit: 200)
            let response = try await itemService.getCollectionItems(userID: userID, query: query)
            collectionItems = response.items
        } catch {
            // Leave collectionItems empty; the view shows its empty state.
        }
    }

    func toggleFavorite() async {
        let oldValue = isFavorite
        isFavorite.toggle()

        do {
            try await itemService.setFavorite(userID: userID, itemID: item.id, isFavorite: isFavorite)
            NotificationCenter.default.post(name: .homeFavoritesDidChange, object: nil)
        } catch {
            isFavorite = oldValue
        }
    }

    /// Effective played state for a card: an in-session override wins,
    /// otherwise the server snapshot on the item.
    func isPlayed(_ item: JellyfinItem) -> Bool {
        playedOverrides[item.id] ?? (item.userData?.played ?? false)
    }

    /// Toggle the top-level item (movie or whole series).
    func togglePlayed() async {
        let oldValue = isPlayed
        isPlayed.toggle()
        playedOverrides[item.id] = isPlayed

        do {
            try await itemService.setPlayed(userID: userID, itemID: item.id, isPlayed: isPlayed)
            NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
        } catch {
            isPlayed = oldValue
            playedOverrides[item.id] = oldValue
        }
    }

    /// Toggle a single episode. `isPlayed` is the desired new state.
    func setEpisodePlayed(_ episode: JellyfinItem, isPlayed: Bool) async {
        let oldValue = playedOverrides[episode.id]
        playedOverrides[episode.id] = isPlayed

        do {
            try await itemService.setPlayed(userID: userID, itemID: episode.id, isPlayed: isPlayed)
            NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
        } catch {
            playedOverrides[episode.id] = oldValue
        }
    }

    /// Toggle a whole season. The server cascades to child episodes; we
    /// additionally flip the override for every episode we have loaded
    /// for that season so the per-episode badges update live.
    func setSeasonPlayed(seasonID: String, isPlayed: Bool) async {
        var affected = Set((episodesCache[seasonID] ?? []).map(\.id))
        if selectedSeasonID == seasonID {
            affected.formUnion(episodes.map(\.id))
        }

        let previous = playedOverrides
        playedOverrides[seasonID] = isPlayed
        for id in affected { playedOverrides[id] = isPlayed }

        do {
            try await itemService.setPlayed(userID: userID, itemID: seasonID, isPlayed: isPlayed)
            NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
        } catch {
            playedOverrides = previous
        }
    }

    // MARK: - Playback Info Pre-fetch

    func prefetchPlaybackInfo(for itemID: String) {
        guard let playbackService else { return }
        // Cancel any older prefetch, only the latest item matters.
        playbackInfoPrefetchTask?.cancel()
        playbackInfoPrefetchTask = Task { [weak self] in
            guard let self else { return }
            let response = try? await playbackService.getPlaybackInfo(
                itemID: itemID, userID: self.userID,
                profile: DirectPlayProfile.current()
            )
            if Task.isCancelled { return }
            self.cachedPlaybackInfo = response
        }
    }

    func posterURL(for item: JellyfinItem) -> URL? {
        imageService.posterURL(for: item)
    }

    func backdropURL(for item: JellyfinItem) -> URL? {
        imageService.backdropURL(for: item)
    }
}
