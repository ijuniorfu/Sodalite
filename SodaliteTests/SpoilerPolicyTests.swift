import Foundation
import Testing
@testable import Sodalite

@Suite("Spoiler policy")
struct SpoilerPolicyTests {
    private func item(
        id: String = "i1",
        type: String = "Episode",
        played: Bool? = nil,
        percentage: Double? = nil
    ) throws -> JellyfinItem {
        var json = #"{"Id":"\#(id)","Name":"N","Type":"\#(type)""#
        if played != nil || percentage != nil {
            var parts: [String] = []
            if let played { parts.append(#""Played":\#(played)"#) }
            if let percentage { parts.append(#""PlayedPercentage":\#(percentage)"#) }
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

    @Test("kinds other than episode and movie are never hidden")
    func otherKindsVisible() throws {
        #expect(!policy().isHidden(try item(type: "Series")))
        #expect(!policy().isHidden(try item(type: "Season")))
        #expect(!policy().isHidden(try item(type: "BoxSet")))
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
}
