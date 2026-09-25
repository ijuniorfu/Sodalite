import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 BROWSE-8. A playlist can hold the same item twice (an imported .m3u, or one
/// built before the server's own add-dedupe), and PlaylistDetailView's ForEach used to key on the
/// bare item id, giving SwiftUI two rows with one identity.
struct PlaylistDetailViewRowIDTests {
    private func item(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self, from: Data("{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Movie\"}".utf8)
        )
    }

    @Test("no duplicates: every id passes through unchanged")
    func noDuplicatesPassThroughUnchanged() throws {
        let items = try [item("a"), item("b"), item("c")]
        #expect(PlaylistDetailView.uniqueRowIDs(for: items) == ["a", "b", "c"])
    }

    @Test("a repeated id is disambiguated, the first occurrence stays bare")
    func repeatedIDIsDisambiguated() throws {
        let items = try [item("a"), item("b"), item("a")]
        let ids = PlaylistDetailView.uniqueRowIDs(for: items)

        #expect(ids.count == 3)
        #expect(Set(ids).count == 3, "duplicate ids still collided: \(ids)")
        #expect(ids[0] == "a", "the first occurrence should keep pure content identity")
        #expect(ids[1] == "b")
        #expect(ids[2] != "a" && ids[2].hasPrefix("a"))
    }

    @Test("three occurrences of the same id all get distinct rows")
    func threeOccurrencesAllDistinct() throws {
        let items = try [item("a"), item("a"), item("a")]
        let ids = PlaylistDetailView.uniqueRowIDs(for: items)
        #expect(Set(ids).count == 3, "duplicate ids still collided: \(ids)")
    }
}
