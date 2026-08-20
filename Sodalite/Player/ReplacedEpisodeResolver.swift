import Foundation

/// The two catalog queries the replacement lookup needs. A narrow face on the playback service so the
/// resolver is exercised without standing up the twenty-method protocol behind it.
protocol EpisodeCatalogQuerying: Sendable {
    func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem]
    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem]
}

/// Decides, from what the server lists NOW, whether the episode this session was asked to play still
/// exists or was replaced by another file.
///
/// Jellyfin derives an item's id from its path (MD5 over the type name plus the normalised path), so a
/// Sonarr upgrade that writes a new filename mints a NEW id and drops the old one at the next scan.
/// Every id this app is holding from before that moment (the successor the player resolved at the start
/// of the current episode, the detail's episode list, a Home row) then names an item the server no longer
/// has, and the play attempt is answered with a status instead of media.
///
/// The status is deliberately not the trigger. Which one a dead id earns depends on the Jellyfin version
/// and on which endpoint the request reached (PlaybackInfo, the stream, a transcode), so a client that
/// keys on 404 misses the rest. The list is unambiguous: ask what the season holds now and compare.
enum ReplacedEpisodeLookup {

    enum Outcome: Equatable {
        /// The season still lists the exact id, so nothing was replaced and the failure has another cause.
        case stillListed
        /// The id is gone and the episode with that number is a different item: the new file.
        case replaced(id: String)
        /// Neither could be established (query failed, season empty, no episode with that number).
        case inconclusive
    }

    static func outcome(staleID: String, episodeNumber: Int?, in episodes: [JellyfinItem]) -> Outcome {
        guard !episodes.isEmpty else { return .inconclusive }
        guard !episodes.contains(where: { $0.id == staleID }) else { return .stillListed }
        guard let episodeNumber,
              let replacement = episodes.first(where: { $0.indexNumber == episodeNumber })
        else { return .inconclusive }
        return .replaced(id: replacement.id)
    }
}

/// Resolves the item that took a vanished episode's place, or nil when nothing did.
struct ReplacedEpisodeResolver: Sendable {
    let service: EpisodeCatalogQuerying
    let userID: String

    func replacement(for stale: JellyfinItem) async -> JellyfinItem? {
        guard let seriesID = stale.seriesId else { return nil }

        if let seasonID = stale.seasonId {
            let episodes = (try? await service.getEpisodes(seriesID: seriesID, seasonID: seasonID, userID: userID)) ?? []
            switch ReplacedEpisodeLookup.outcome(staleID: stale.id, episodeNumber: stale.indexNumber, in: episodes) {
            case .stillListed:
                return nil
            case .replaced(let id):
                return episodes.first { $0.id == id }
            case .inconclusive:
                break
            }
        }

        // A season id is path-derived too, so a rename of the season folder takes it along with the
        // episode. Resolve the season by its number before giving up.
        guard let seasonNumber = stale.parentIndexNumber,
              let seasons = try? await service.getSeasons(seriesID: seriesID, userID: userID),
              let season = seasons.first(where: { $0.indexNumber == seasonNumber }),
              season.id != stale.seasonId,
              let episodes = try? await service.getEpisodes(seriesID: seriesID, seasonID: season.id, userID: userID),
              case .replaced(let id) = ReplacedEpisodeLookup.outcome(
                  staleID: stale.id, episodeNumber: stale.indexNumber, in: episodes)
        else { return nil }

        return episodes.first { $0.id == id }
    }
}
