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
    var cachedPlaybackInfo: PlaybackInfoResponse?

    private let itemService: JellyfinItemServiceProtocol
    private let libraryService: JellyfinLibraryServiceProtocol?
    private let playbackService: JellyfinPlaybackServiceProtocol?
    private let imageService: JellyfinImageService
    private let userID: String
    /// In-flight prefetch task, cancelled on deinit so a disappearing
    /// view doesn't keep self alive waiting on network. `nonisolated(unsafe)`
    /// is required because `deinit` on an actor-isolated class runs
    /// nonisolated, and the plain `nonisolated` fix-it the compiler
    /// suggests fails to build here: @Observable expands to a stored-var
    /// backing that Swift doesn't allow `nonisolated` on. Task<Void, Never>
    /// is Sendable so the cancel call itself is safe.
    nonisolated(unsafe) private var prefetchTask: Task<Void, Never>?

    /// Per-season episode cache. Hit on `loadEpisodes(seasonID:)` so a
    /// season tab the user has already (or pre-emptively) visited
    /// switches in instantly instead of doing another round trip.
    private var episodesCache: [String: [JellyfinItem]] = [:]

    deinit {
        prefetchTask?.cancel()
    }

    init(
        item: JellyfinItem,
        itemService: JellyfinItemServiceProtocol,
        imageService: JellyfinImageService,
        userID: String,
        libraryService: JellyfinLibraryServiceProtocol? = nil,
        playbackService: JellyfinPlaybackServiceProtocol? = nil
    ) {
        self.item = item
        self.isFavorite = item.userData?.isFavorite ?? false
        self.isPlayed = item.userData?.played ?? false
        self.itemService = itemService
        self.libraryService = libraryService
        self.playbackService = playbackService
        self.imageService = imageService
        self.userID = userID
    }

    func loadFullDetail() async {
        isLoading = true

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

        if itemType != .series && itemType != .boxSet {
            prefetchPlaybackInfo(for: itemID)
        }

        // Wait for the parallel chains to finish so isLoading flips
        // false at the latest once every section has its data. On
        // fast servers this fires before the deadline above; on slow
        // servers the deadline already flipped it false and this is
        // a no-op.
        await seriesContentTask?.value
        await collectionContentTask?.value

        isLoading = false
    }

    func loadSeasons() async {
        guard item.type == .series else { return }

        // Three independent fetches all keyed off the series ID:
        //   - getSeasons:  the season-tabs list
        //   - getNextUp:   the resume target (if any)
        //   - loadEpisodes: needs a season ID, but next-up gives us
        //                  one as soon as it lands, so we wait
        //                  ONLY on next-up before kicking that off,
        //                  not on the seasons response.
        let seasonsTask = Task { try? await itemService.getSeasons(seriesID: item.id, userID: userID) }
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

    }

    func loadEpisodes(seasonID: String) async {
        selectedSeasonID = seasonID

        if let cached = episodesCache[seasonID] {
            episodes = cached
            return
        }

        do {
            let response = try await itemService.getEpisodes(seriesID: item.id, seasonID: seasonID, userID: userID)
            episodes = response.items
            episodesCache[seasonID] = response.items
        } catch {
            // Handle error
        }
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
            // Handle error
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
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
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
