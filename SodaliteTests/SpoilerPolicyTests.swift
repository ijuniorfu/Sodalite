import Foundation
import Testing
@testable import Sodalite

@Suite("Spoiler policy")
struct SpoilerPolicyTests {
    private func item(
        id: String = "i1",
        type: String = "Episode",
        played: Bool? = nil,
        percentage: Double? = nil,
        childCount: Int? = nil,
        unplayed: Int? = nil
    ) throws -> JellyfinItem {
        var json = #"{"Id":"\#(id)","Name":"N","Type":"\#(type)""#
        if let childCount { json += #","ChildCount":\#(childCount)"# }
        if played != nil || percentage != nil || unplayed != nil {
            var parts: [String] = []
            if let played { parts.append(#""Played":\#(played)"#) }
            if let percentage { parts.append(#""PlayedPercentage":\#(percentage)"#) }
            if let unplayed { parts.append(#""UnplayedItemCount":\#(unplayed)"#) }
            json += #","UserData":{"# + parts.joined(separator: ",") + "}"
        }
        json += "}"
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func policy(
        enabled: Bool = true,
        episodes: Bool = true,
        movies: Bool = true,
        revealed: Set<String> = []
    ) -> SpoilerPolicy {
        SpoilerPolicy(
            enabled: enabled,
            hideEpisodes: episodes,
            hideMovies: movies,
            userID: "u1",
            revealedKeys: revealed
        )
    }

    @Test("an unwatched episode is hidden")
    func unwatchedEpisodeHidden() throws {
        #expect(policy().isHidden(try item()))
    }

    @Test("the master switch beats everything")
    func masterSwitchOff() throws {
        #expect(!policy(enabled: false).isHidden(try item()))
    }

    @Test("each kind honours its own switch")
    func perKindSwitches() throws {
        #expect(!policy(episodes: false).isHidden(try item(type: "Episode")))
        #expect(policy(episodes: false).isHidden(try item(type: "Movie")))
        #expect(!policy(movies: false).isHidden(try item(type: "Movie")))
        #expect(policy(movies: false).isHidden(try item(type: "Episode")))
    }

    @Test("kinds other than episode, season and movie are never hidden")
    func otherKindsVisible() throws {
        #expect(!policy().isHidden(try item(type: "Series")))
        #expect(!policy().isHidden(try item(type: "BoxSet")))
    }

    // MARK: Seasons

    @Test("an unwatched season's synopsis is hidden, under the episode switch")
    func unwatchedSeasonHidden() throws {
        #expect(policy().isHidden(try item(type: "Season")))
        #expect(!policy(episodes: false).isHidden(try item(type: "Season")))
    }

    @Test("a fully played season reveals")
    func playedSeasonReveals() throws {
        #expect(!policy().isHidden(try item(type: "Season", played: true)))
    }

    @Test("one watched episode reveals the season, the percentage a season never carries")
    func startedSeasonReveals() throws {
        #expect(!policy().isHidden(try item(type: "Season", childCount: 10, unplayed: 9)))
        #expect(policy().isHidden(try item(type: "Season", childCount: 10, unplayed: 10)))
        // Counts missing (a caller that didn't ask for ChildCount): no evidence of a start, stay hidden.
        #expect(policy().isHidden(try item(type: "Season", unplayed: 9)))
        #expect(policy().isHidden(try item(type: "Season", childCount: 10)))
    }

    @Test("a season's artwork is never veiled, only its synopsis")
    func seasonArtworkStaysVisible() throws {
        let season = try item(type: "Season")
        #expect(policy().isHidden(season, surface: .text))
        #expect(!policy().isHidden(season, surface: .artwork))
    }

    @Test("played reveals")
    func playedReveals() throws {
        #expect(!policy().isHidden(try item(played: true)))
    }

    @Test("started reveals, which is what keeps Continue Watching readable")
    func startedReveals() throws {
        #expect(!policy().isHidden(try item(percentage: 0.4)))
        #expect(policy().isHidden(try item(percentage: 0)))
    }

    @Test("an explicitly revealed key is visible")
    func manualRevealVisible() throws {
        let key = SpoilerPolicy.key(userID: "u1", itemID: "i1")
        #expect(!policy(revealed: [key]).isHidden(try item(id: "i1")))
        #expect(policy(revealed: [key]).isHidden(try item(id: "i2")))
    }

    @Test("the key is scoped per user and per item, not per series")
    func keyShape() throws {
        #expect(SpoilerPolicy.key(userID: "u1", itemID: "i1") == "u1|i1")
        #expect(policy().key(for: try item(id: "abc")) == "u1|abc")
    }

    @Test("the disabled policy hides nothing")
    func disabledConstant() throws {
        #expect(!SpoilerPolicy.disabled.isHidden(try item()))
    }

    // MARK: Surfaces

    @Test("a movie's artwork is never veiled, only its description")
    func movieArtworkStaysVisible() throws {
        let movie = try item(type: "Movie")
        #expect(policy().isHidden(movie, surface: .text))
        #expect(!policy().isHidden(movie, surface: .artwork))
    }

    @Test("an episode's still is veiled alongside its synopsis")
    func episodeArtworkVeiled() throws {
        let episode = try item(type: "Episode")
        #expect(policy().isHidden(episode, surface: .text))
        #expect(policy().isHidden(episode, surface: .artwork))
    }

    @Test("both surfaces still answer to the base decision")
    func surfacesRespectBaseDecision() throws {
        let watched = try item(type: "Episode", played: true)
        #expect(!policy().isHidden(watched, surface: .text))
        #expect(!policy().isHidden(watched, surface: .artwork))
        #expect(!policy(enabled: false).isHidden(try item(), surface: .artwork))
    }

    @Test("the veil styles map onto the surfaces")
    func styleSurfaceMapping() {
        #expect(SpoilerVeilStyle.image.surface == .artwork)
        #expect(SpoilerVeilStyle.text.surface == .text)
    }
}
