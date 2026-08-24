import Testing
import Foundation
@testable import Sodalite

/// The library grids' sort choice (Sodalite#78): what it sends to Jellyfin, what it stores, and what
/// it does with a value it cannot read.
struct LibrarySortTests {

    @Test("the default is what every grid shipped with before the picker existed")
    func defaultMatchesShippedBehaviour() {
        #expect(LibrarySort.default.jellyfinSortBy == "SortName")
        #expect(LibrarySort.default.jellyfinSortOrder == "Ascending")
    }

    @Test("every key maps to a Jellyfin sort field")
    func keysMapToJellyfin() {
        let expected: [LibrarySortKey: String] = [
            .title: "SortName",
            .releaseDate: "PremiereDate",
            .dateAdded: "DateCreated",
            .rating: "CommunityRating",
            .runtime: "Runtime"
        ]
        for key in LibrarySortKey.allCases {
            #expect(key.jellyfinValue == expected[key], "\(key.rawValue) lost its Jellyfin field")
        }
    }

    /// Ties would otherwise come back in an order that is not stable between requests, and the grid
    /// paginates: an unstable order duplicates items on one page and drops them from the next.
    @Test("non-title keys carry SortName as the tiebreaker")
    func tiebreaker() {
        for key in LibrarySortKey.allCases where key != .title {
            let sort = LibrarySort(key: key, descending: true)
            #expect(sort.jellyfinSortBy == "\(key.jellyfinValue),SortName")
        }
        #expect(LibrarySort(key: .title, descending: true).jellyfinSortBy == "SortName")
    }

    @Test("the sort replaces whatever the tile query was built with")
    func appliedOverridesQuery() {
        let query = ItemQuery(sortBy: "SortName", sortOrder: "Ascending", fields: "")
        let applied = LibrarySort(key: .rating, descending: true).applied(to: query)
        #expect(applied.sortBy == "CommunityRating,SortName")
        #expect(applied.sortOrder == "Descending")
    }

    @Test("storage survives a round trip")
    func storageRoundTrip() {
        for key in LibrarySortKey.allCases {
            for descending in [true, false] {
                let sort = LibrarySort(key: key, descending: descending)
                #expect(LibrarySort(storedValue: sort.storageValue) == sort)
            }
        }
    }

    /// A missing value is a fresh install, an unreadable one a key written by a newer build. Neither
    /// may fail the read: the grid has to render something.
    @Test("unreadable stored values fall back to the default")
    func tolerantDecode() {
        #expect(LibrarySort(storedValue: nil) == .default)
        #expect(LibrarySort(storedValue: "") == .default)
        #expect(LibrarySort(storedValue: "fileSize:desc") == .default)
        #expect(LibrarySort(storedValue: ":::") == .default)
    }

    /// A key from a newer build arrives without its direction only if the format changes; a known key
    /// without one still has to land on that key's natural direction rather than ascending-by-accident.
    @Test("a stored key without a direction takes the key's natural one")
    func directionlessValue() {
        #expect(LibrarySort(storedValue: "releaseDate") == LibrarySort(key: .releaseDate, descending: true))
        #expect(LibrarySort(storedValue: "title") == LibrarySort(key: .title, descending: false))
    }

    @Test("picking the active key flips it, picking another adopts its natural direction")
    func toggling() {
        let titleAscending = LibrarySort(key: .title, descending: false)
        #expect(titleAscending.toggled(to: .title) == LibrarySort(key: .title, descending: true))
        #expect(titleAscending.toggled(to: .rating) == LibrarySort(key: .rating, descending: true))
        #expect(titleAscending.toggled(to: .rating).toggled(to: .rating)
                == LibrarySort(key: .rating, descending: false))
    }

    @Test("direction wording is specific to the key")
    func directionWordingDiffers() {
        #expect(LibrarySortKey.title.localizedDirection(descending: false)
                != LibrarySortKey.rating.localizedDirection(descending: false))
    }
}

/// The per-server store behind the picker, including the shape `collectServerPayload` publishes.
struct LibrarySortStoreTests {

    private func scope(_ key: String, serverID: String) -> LibrarySortScope {
        LibrarySortScope(serverID: serverID, key: key)
    }

    private func cleanUp(serverID: String) {
        for (key, _) in UserDefaults.standard.dictionaryRepresentation()
        where key.hasPrefix("librarySort.\(serverID).") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test("an untouched scope reads as the default")
    func untouchedScope() {
        let serverID = "test-\(UUID().uuidString)"
        defer { cleanUp(serverID: serverID) }
        #expect(LibrarySortStore.sort(scope("library-1", serverID: serverID)) == .default)
    }

    @Test("scopes on the same server stay independent")
    func scopesAreIndependent() {
        let serverID = "test-\(UUID().uuidString)"
        defer { cleanUp(serverID: serverID) }
        let movies = LibrarySortScope.library(id: "movies", serverID: serverID)
        let shows = LibrarySortScope.library(id: "shows", serverID: serverID)

        LibrarySortStore.setSort(LibrarySort(key: .dateAdded, descending: true), scope: movies)

        #expect(LibrarySortStore.sort(movies) == LibrarySort(key: .dateAdded, descending: true))
        #expect(LibrarySortStore.sort(shows) == .default)
    }

    @Test("two servers do not share a scope key")
    func serversAreIndependent() {
        let serverA = "test-\(UUID().uuidString)"
        let serverB = "test-\(UUID().uuidString)"
        defer { cleanUp(serverID: serverA); cleanUp(serverID: serverB) }

        LibrarySortStore.setSort(
            LibrarySort(key: .runtime, descending: false),
            scope: .library(id: "movies", serverID: serverA)
        )

        #expect(LibrarySortStore.sort(.library(id: "movies", serverID: serverB)) == .default)
        #expect(LibrarySortStore.allSorts(serverID: serverB).isEmpty)
    }

    /// The default is written out rather than removed: collect publishes the whole map, so a removed
    /// entry would read as "never touched" and let a stale remote value win the reset.
    @Test("resetting to the default still publishes an entry")
    func resetIsPublished() {
        let serverID = "test-\(UUID().uuidString)"
        defer { cleanUp(serverID: serverID) }
        let movies = LibrarySortScope.library(id: "movies", serverID: serverID)

        LibrarySortStore.setSort(LibrarySort(key: .rating, descending: true), scope: movies)
        LibrarySortStore.setSort(.default, scope: movies)

        #expect(LibrarySortStore.allSorts(serverID: serverID)["library-movies"] == LibrarySort.default.storageValue)
    }

    @Test("a payload's map applies per scope and leaves unmentioned tiles alone")
    func applyMergesPerScope() {
        let serverID = "test-\(UUID().uuidString)"
        defer { cleanUp(serverID: serverID) }
        let movies = LibrarySortScope.library(id: "movies", serverID: serverID)
        let shows = LibrarySortScope.library(id: "shows", serverID: serverID)
        LibrarySortStore.setSort(LibrarySort(key: .runtime, descending: true), scope: shows)

        LibrarySortStore.applySorts(
            ["library-movies": LibrarySort(key: .releaseDate, descending: true).storageValue],
            serverID: serverID
        )

        #expect(LibrarySortStore.sort(movies) == LibrarySort(key: .releaseDate, descending: true))
        #expect(LibrarySortStore.sort(shows) == LibrarySort(key: .runtime, descending: true))
    }

    @Test("collect and apply round-trip a server's whole map")
    func collectApplyRoundTrip() {
        let source = "test-\(UUID().uuidString)"
        let target = "test-\(UUID().uuidString)"
        defer { cleanUp(serverID: source); cleanUp(serverID: target) }

        LibrarySortStore.setSort(
            LibrarySort(key: .dateAdded, descending: true), scope: .library(id: "movies", serverID: source)
        )
        LibrarySortStore.setSort(
            LibrarySort(key: .title, descending: true), scope: .genre(name: "Sci-Fi", serverID: source)
        )

        LibrarySortStore.applySorts(LibrarySortStore.allSorts(serverID: source), serverID: target)

        #expect(LibrarySortStore.sort(.library(id: "movies", serverID: target))
                == LibrarySort(key: .dateAdded, descending: true))
        #expect(LibrarySortStore.sort(.genre(name: "Sci-Fi", serverID: target))
                == LibrarySort(key: .title, descending: true))
    }
}

/// The cloud mirror of the sort map, sharing `HomeRowsSyncState` with the home-row settings.
struct LibrarySortSyncTests {
    /// The field is optional so payloads written by older builds still decode; a non-optional
    /// addition would fail the whole ServerSyncPayload and drop the server from sync.
    @Test func decodesPayloadWrittenBeforeTheFieldExisted() throws {
        let legacy = Data(#"{"mergeCWNextUp":true,"rewatchNextUp":false}"#.utf8)
        let decoded = try JSONDecoder().decode(HomeRowsSyncState.self, from: legacy)
        #expect(decoded.librarySorts == nil)
    }

    @Test func roundTripsTheSortMap() throws {
        let state = HomeRowsSyncState(
            configsJSON: nil,
            mergeCWNextUp: false,
            rewatchNextUp: false,
            collectionGrouping: nil,
            librarySorts: ["library-movies": "dateAdded:desc", "genre-Sci-Fi": "title:asc"]
        )
        let decoded = try JSONDecoder().decode(
            HomeRowsSyncState.self, from: try JSONEncoder().encode(state)
        )
        #expect(decoded == state)
    }
}
