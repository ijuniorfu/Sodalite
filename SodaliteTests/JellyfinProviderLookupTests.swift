import Testing
import Foundation
@testable import Sodalite

/// Jellyfin has no server-side provider-id filter: `AnyProviderIdEquals` is an Emby parameter and
/// Jellyfin drops unknown query items without complaining. A query that looked like a lookup
/// therefore returned whatever the library sorted first, and `Limit=1` dressed that up as a hit
/// (asking for Game of Thrones handed back Blue's Clues). Every candidate must be verified.
@MainActor
struct JellyfinProviderLookupTests {
    private func item(_ providerIds: [String: String]?) throws -> JellyfinItem {
        let ids = providerIds.map { dict in
            "," + "\"ProviderIds\":{" + dict.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}"
        } ?? ""
        let json = "{\"Id\":\"abc\",\"Name\":\"Whatever\",\"Type\":\"Series\"\(ids)}"
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    @Test func matchesTheRequestedProviderID() throws {
        let got = try item(["Tmdb": "1399"])
        #expect(got.carriesProviderID("tmdb.1399") == true)
    }

    /// The exact regression: an unrelated library item must never pass as a match.
    @Test func rejectsAnUnrelatedItem() throws {
        let bluesClues = try item(["Tmdb": "2593"])
        #expect(bluesClues.carriesProviderID("tmdb.1399") == false)
    }

    /// Older scanners wrote lowercase keys, and imdb ids carry letters.
    @Test func matchesCaseInsensitivelyAcrossProviders() throws {
        #expect(try item(["tmdb": "1399"]).carriesProviderID("tmdb.1399") == true)
        #expect(try item(["Tvdb": "121361"]).carriesProviderID("tvdb.121361") == true)
        #expect(try item(["Imdb": "TT0944947"]).carriesProviderID("imdb.tt0944947") == true)
    }

    /// A different provider holding the same number is not a match.
    @Test func doesNotMatchAcrossProviders() throws {
        #expect(try item(["Tvdb": "1399"]).carriesProviderID("tmdb.1399") == false)
    }

    @Test func itemWithoutProviderIDsNeverMatches() throws {
        #expect(try item(nil).carriesProviderID("tmdb.1399") == false)
    }

    @Test func malformedQualifierNeverMatches() throws {
        let got = try item(["Tmdb": "1399"])
        #expect(got.carriesProviderID("1399") == false)
        #expect(got.carriesProviderID("") == false)
    }

    /// The value may itself contain dots (some scanners store suffixed ids), so only the first separator splits.
    @Test func splitsOnlyOnTheFirstSeparator() throws {
        #expect(try item(["Imdb": "tt09.44947"]).carriesProviderID("imdb.tt09.44947") == true)
    }
}
