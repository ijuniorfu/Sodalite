import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// A Sonarr upgrade rewrites an episode file, and because Jellyfin ids an item by its path the library
/// answers with a NEW id and drops the old one. Every id the app holds from before that moment names an
/// item the server no longer has, and playing it earns a status instead of media.
///
/// The status is not the discriminator: the reporter of this defect saw several and could not name one,
/// which matches Jellyfin answering differently per version and per endpoint (PlaybackInfo, the stream,
/// a transcode). What is unambiguous is the season list, so these tests pin the lookup to it.
struct ReplacedEpisodeRecoveryTests {
    /// Stands in for what `player.load()` throws: the engine's own error type is internal to the
    /// package, so the host only ever sees an opaque Error plus `player.errorInfo`.
    struct EngineLoadFailure: Error {}


    private func episode(
        id: String,
        seriesID: String? = "series",
        seasonID: String? = "season-1",
        number: Int?,
        seasonNumber: Int? = 1
    ) throws -> JellyfinItem {
        var fields = ["\"Id\":\"\(id)\"", "\"Name\":\"Episode\"", "\"Type\":\"Episode\""]
        if let seriesID { fields.append("\"SeriesId\":\"\(seriesID)\"") }
        if let seasonID { fields.append("\"SeasonId\":\"\(seasonID)\"") }
        if let number { fields.append("\"IndexNumber\":\(number)") }
        if let seasonNumber { fields.append("\"ParentIndexNumber\":\(seasonNumber)") }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func season(id: String, number: Int) throws -> JellyfinItem {
        let json = "{\"Id\":\"\(id)\",\"Name\":\"Season\",\"Type\":\"Season\",\"IndexNumber\":\(number)}"
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    /// Answers exactly what a server would: an unknown season id is a failure, not an empty list.
    private struct Catalog: EpisodeCatalogQuerying {
        var seasons: [JellyfinItem] = []
        var episodesBySeason: [String: [JellyfinItem]] = [:]

        func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem] {
            guard !seasons.isEmpty else { throw APIError.httpError(statusCode: 404, data: nil) }
            return seasons
        }

        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem] {
            guard let list = episodesBySeason[seasonID] else {
                throw APIError.httpError(statusCode: 404, data: nil)
            }
            return list
        }
    }

    // MARK: - Lookup

    @Test func listingTheIdWeTriedMeansNothingWasReplaced() throws {
        let outcome = ReplacedEpisodeLookup.outcome(
            staleID: "ep-old",
            episodeNumber: 3,
            in: [try episode(id: "ep-old", number: 3), try episode(id: "ep-4", number: 4)]
        )
        #expect(outcome == .stillListed)
    }

    @Test func aMissingIdResolvesToTheEpisodeWithTheSameNumber() throws {
        let outcome = ReplacedEpisodeLookup.outcome(
            staleID: "ep-old",
            episodeNumber: 3,
            in: [try episode(id: "ep-2", number: 2), try episode(id: "ep-new", number: 3)]
        )
        #expect(outcome == .replaced(id: "ep-new"))
    }

    /// The episode was deleted rather than upgraded: nothing to continue on.
    @Test func aMissingIdWithNoEpisodeOfThatNumberIsInconclusive() throws {
        let outcome = ReplacedEpisodeLookup.outcome(
            staleID: "ep-old",
            episodeNumber: 3,
            in: [try episode(id: "ep-2", number: 2)]
        )
        #expect(outcome == .inconclusive)
    }

    /// An empty list is the shape a failed query degrades to, and it proves nothing: treating it as
    /// "the id is gone" would swap items on every server hiccup.
    @Test func anEmptyListIsInconclusiveRatherThanProofOfRemoval() {
        #expect(ReplacedEpisodeLookup.outcome(staleID: "ep-old", episodeNumber: 3, in: []) == .inconclusive)
    }

    /// Without a number there is no axis to match on, so a missing id stays unresolved.
    @Test func aMissingIdWithoutAnEpisodeNumberIsInconclusive() throws {
        let outcome = ReplacedEpisodeLookup.outcome(
            staleID: "ep-old",
            episodeNumber: nil,
            in: [try episode(id: "ep-new", number: 3)]
        )
        #expect(outcome == .inconclusive)
    }

    // MARK: - Resolver

    @Test func resolverReturnsTheEpisodeThatTookThePlaceOfTheDeadId() async throws {
        let stale = try episode(id: "ep-old", number: 3)
        let catalog = Catalog(episodesBySeason: [
            "season-1": [try episode(id: "ep-new", number: 3), try episode(id: "ep-4", number: 4)]
        ])
        let resolved = await ReplacedEpisodeResolver(service: catalog, userID: "u").replacement(for: stale)
        #expect(resolved?.id == "ep-new")
    }

    @Test func resolverStaysSilentWhileTheServerStillListsTheId() async throws {
        let stale = try episode(id: "ep-old", number: 3)
        let catalog = Catalog(episodesBySeason: ["season-1": [try episode(id: "ep-old", number: 3)]])
        let resolved = await ReplacedEpisodeResolver(service: catalog, userID: "u").replacement(for: stale)
        #expect(resolved == nil)
    }

    /// A season id is path-derived too, so renaming the season folder kills it along with the episode.
    /// The season number survives that, and it is the only way back to the new episode id.
    @Test func resolverFallsBackToTheSeasonNumberWhenTheSeasonIdDiedToo() async throws {
        let stale = try episode(id: "ep-old", seasonID: "season-old", number: 3, seasonNumber: 2)
        let catalog = Catalog(
            seasons: [try season(id: "season-new", number: 2)],
            episodesBySeason: ["season-new": [try episode(id: "ep-new", seasonID: "season-new", number: 3)]]
        )
        let resolved = await ReplacedEpisodeResolver(service: catalog, userID: "u").replacement(for: stale)
        #expect(resolved?.id == "ep-new")
    }

    @Test func resolverGivesUpWhenTheSeriesItselfIsGone() async throws {
        let stale = try episode(id: "ep-old", number: 3)
        let resolved = await ReplacedEpisodeResolver(service: Catalog(), userID: "u").replacement(for: stale)
        #expect(resolved == nil)
    }

    /// A movie has no series/season/number axis, so there is nothing deterministic to resolve it to.
    @Test func resolverIgnoresAnItemWithoutASeries() async throws {
        let stale = try episode(id: "movie", seriesID: nil, seasonID: nil, number: nil, seasonNumber: nil)
        let catalog = Catalog(episodesBySeason: ["season-1": [try episode(id: "ep-new", number: 3)]])
        let resolved = await ReplacedEpisodeResolver(service: catalog, userID: "u").replacement(for: stale)
        #expect(resolved == nil)
    }

    // MARK: - Trigger

    /// The whole point of asking the library: every answered status qualifies, because the reporter saw
    /// several and no single one identifies a replaced file.
    @Test(arguments: [400, 401, 402, 403, 404, 410, 500])
    func everyAnsweredStatusAsksTheLibrary(status: Int) {
        #expect(ReplacedItemRecoveryTrigger.serverAnswered(
            hostError: APIError.httpError(statusCode: status, data: nil), engineError: nil))
    }

    /// 401 arrives as its own case, not as httpError, and it has to qualify the same way.
    @Test func anExpiredSessionStillAsksTheLibrary() {
        #expect(ReplacedItemRecoveryTrigger.serverAnswered(
            hostError: APIError.unauthorized(message: nil), engineError: nil))
    }

    /// Nothing reached a server here, so there is no verdict about the item to act on.
    @Test func aFailureThatNeverReachedTheServerIsNotProbed() {
        #expect(!ReplacedItemRecoveryTrigger.serverAnswered(hostError: APIError.timeout, engineError: nil))
        #expect(!ReplacedItemRecoveryTrigger.serverAnswered(hostError: APIError.serverUnreachable, engineError: nil))
        #expect(!ReplacedItemRecoveryTrigger.serverAnswered(hostError: APIError.invalidResponse, engineError: nil))
        #expect(!ReplacedItemRecoveryTrigger.serverAnswered(hostError: CancellationError(), engineError: nil))
    }

    /// The failure that made the recovery worth building does NOT arrive as an APIError. Where the detail
    /// screen prefetched PlaybackInfo, the load makes no request of its own, so the only thing that can
    /// fail is `player.load()`, and the engine's `AVIOReaderError` is internal to the package. Matching on
    /// APIError alone therefore left `ranOnPrefetchedInfo` unreachable by construction. The engine's typed
    /// classification is the answer the origin gave, so it qualifies the same way a status does.
    @Test func anOriginRefusalTypedByTheEngineAsksTheLibraryToo() {
        #expect(ReplacedItemRecoveryTrigger.serverAnswered(
            hostError: EngineLoadFailure(),
            engineError: PlaybackErrorInfo(
                kind: .sourceRefused,
                message: "Failed to load: Origin answered HTTP 400 for the source",
                underlyingCode: 400)))
    }

    /// A metered origin is not a verdict about the item: the source is there and the same request is
    /// expected to work later, so re-asking (and restarting on it) is the one reaction the engine
    /// explicitly warns against.
    @Test func aMeteredOriginIsNotAVerdictAboutTheItem() {
        #expect(!ReplacedItemRecoveryTrigger.serverAnswered(
            hostError: EngineLoadFailure(),
            engineError: PlaybackErrorInfo(
                kind: .sourceRateLimited,
                message: "Failed to load: Origin answered HTTP 429 for the source",
                underlyingCode: 429)))
    }

    /// Everything the engine could not type says nothing about the item, the same way a timeout does not.
    @Test func anUntypedOrOpenFailureStillSaysNothingAboutTheItem() {
        #expect(!ReplacedItemRecoveryTrigger.serverAnswered(
            hostError: EngineLoadFailure(), engineError: nil))
        #expect(!ReplacedItemRecoveryTrigger.serverAnswered(
            hostError: EngineLoadFailure(),
            engineError: PlaybackErrorInfo(
                kind: .sourceOpenFailed,
                message: "Failed to load: timed out",
                underlyingDomain: "NSURLErrorDomain", underlyingCode: -1001)))
    }

    /// The five preconditions, pinned as a combination rather than as five guards read in a row.
    @Test func onlyAResolvableVodSessionThatHasNotAskedYetMayAsk() {
        func canAsk(
            live: Bool = false,
            tearingDown: Bool = false,
            asked: Bool = false,
            episode: Bool = true,
            movieWithService: Bool = false
        ) -> Bool {
            ReplacedItemRecoveryTrigger.canAsk(
                isLiveSession: live,
                isTearingDown: tearingDown,
                alreadyAsked: asked,
                isEpisode: episode,
                isMovieWithItemService: movieWithService
            )
        }
        #expect(canAsk())
        #expect(canAsk(episode: false, movieWithService: true))
        // A live channel has no library item to resolve, and a session on its way out has no use for one.
        #expect(!canAsk(live: true))
        #expect(!canAsk(tearingDown: true))
        // The answer is the library's; asking again for the same case only stalls the screen.
        #expect(!canAsk(asked: true))
        // A movie without an item service, and anything that is neither (a recording, a trailer).
        #expect(!canAsk(episode: false))
        #expect(!canAsk(episode: false, movieWithService: false))
    }

}
