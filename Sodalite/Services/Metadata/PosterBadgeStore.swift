import Foundation
import Observation

/// Fetches the half of the badge data that is not free (Sodalite#79).
///
/// Resolution rides along on every card query, but dynamic range and spatial audio only exist in
/// `MediaStreams`, and Jellyfin's DtoService answers that field with a `GetStaticMediaSources` call
/// per item, which is exactly the cost Sodalite#68 took out of the grids. So the streams are never
/// part of the card field set: they are fetched afterwards, batched by id, cached per item, and the
/// result lives here rather than in `FilterCache`, whose keys must keep carrying one single field
/// set no matter who writes them.
@Observable
@MainActor
final class PosterBadgeStore {

    /// Movies and episodes answer for themselves; a series has no streams of its own, so it is
    /// sampled from its newest episode. Everything else (collections, folders, playlists, music)
    /// is never asked about.
    private static let batchSize = 40

    private let library: JellyfinLibraryServiceProtocol
    private let isEnabled: @MainActor () -> Bool

    /// Item id -> what its streams said. An entry with empty badges is a negative result and stops
    /// the id from being asked about again.
    private var enriched: [String: MediaBadges] = [:]
    private var inFlight: Set<String> = []
    /// Tail of the series-sampling chain. Home shows several rows at once, each with its own task,
    /// so per-row serialisation would still let ten rows fan out; the chain makes it one sample at
    /// a time for the whole app.
    private var seriesTail: Task<Void, Never>?

    /// `userID` is passed per call rather than resolved here: `DependencyContainer.activeUserID`
    /// reads the keychain, and the callers hold `AppState.activeUser?.id` already (same reason
    /// `spoilerPolicy(userID:)` takes it as a parameter, Sodalite#50).
    init(library: JellyfinLibraryServiceProtocol,
         isEnabled: @escaping @MainActor () -> Bool) {
        self.library = library
        self.isEnabled = isEnabled
    }

    /// What the card should paint right now: the free resolution immediately, anything the
    /// enrichment has since found layered on top.
    func badges(for item: JellyfinItem) -> MediaBadges {
        let base = MediaBadgeResolver.badges(width: item.width, streams: item.mediaStreams)
        guard let found = enriched[item.id] else { return base }
        return MediaBadges(resolution: found.resolution ?? base.resolution,
                           dynamicRange: found.dynamicRange ?? base.dynamicRange,
                           audio: found.audio ?? base.audio)
    }

    func enrich(userID: String, _ items: [JellyfinItem]) async {
        guard isEnabled() else { return }

        var direct: [String] = []
        var series: [String] = []
        // An item that already carries its streams (anything fetched with detailFields) answers
        // itself; asking the server again would buy nothing.
        for item in items where enriched[item.id] == nil && !inFlight.contains(item.id)
                                && item.mediaStreams == nil {
            switch item.type {
            case .movie, .episode: direct.append(item.id)
            case .series:          series.append(item.id)
            default:               continue
            }
        }
        guard !direct.isEmpty || !series.isEmpty else { return }

        inFlight.formUnion(direct)
        inFlight.formUnion(series)
        defer {
            inFlight.subtract(direct)
            inFlight.subtract(series)
        }

        for start in stride(from: 0, to: direct.count, by: Self.batchSize) {
            await fetchBatch(Array(direct[start..<min(start + Self.batchSize, direct.count)]), userID: userID)
        }
        // Series go one at a time on purpose: a sample cannot be batched with another series', and
        // the request limiter is strict FIFO without a priority lane (Sodalite#72), so a fan-out
        // here would put a user's tap behind twenty background reads.
        for id in series {
            await enqueueSample(id, userID: userID)
        }
    }

    private func fetchBatch(_ ids: [String], userID: String) async {
        let response: JellyfinItemsResponse
        do {
            response = try await library.getItems(
                userID: userID,
                query: ItemQuery(ids: ids, fields: "MediaStreams"))
        } catch {
            return  // Nothing cached, so a later pass over the same row tries again.
        }
        // Seed every requested id, not just the answered ones: an item the server says nothing
        // about must not be asked a second time on every scroll.
        var found = Dictionary(uniqueKeysWithValues: ids.map { ($0, MediaBadges()) })
        for item in response.items {
            found[item.id] = MediaBadgeResolver.badges(width: item.width, streams: item.mediaStreams)
        }
        enriched.merge(found) { _, new in new }
    }

    private func enqueueSample(_ seriesID: String, userID: String) async {
        let previous = seriesTail
        let sample = Task { @MainActor [weak self] in
            await previous?.value
            await self?.sampleSeries(seriesID, userID: userID)
        }
        seriesTail = sample
        await sample.value
    }

    private func sampleSeries(_ seriesID: String, userID: String) async {
        let query = ItemQuery(parentID: seriesID,
                              includeItemTypes: [.episode],
                              sortBy: "DateCreated",
                              sortOrder: "Descending",
                              limit: 1,
                              fields: "MediaStreams")
        guard let response = try? await library.getItems(userID: userID, query: query) else { return }
        enriched[seriesID] = response.items.first.map {
            MediaBadgeResolver.badges(width: $0.width, streams: $0.mediaStreams)
        } ?? MediaBadges()
    }
}
