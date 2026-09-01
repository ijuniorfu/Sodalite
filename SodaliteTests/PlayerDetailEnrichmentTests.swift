import Testing
import Foundation
@testable import Sodalite

/// Chapters and the trickplay manifest ride on the item, and only `detailFields` asks for them. Every
/// route that starts an episode (the series Play button, an episode row, auto-advance, the in-player
/// season picker) hands the player a slim list item, so the player fetches its own detail instead of
/// trusting the caller to have requested the right fields (Sodalite#94, second cause).
@MainActor
struct PlayerDetailEnrichmentTests {
    private func decodeItem(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private var detailJSON: String {
        """
        {"Id":"e1","Name":"E1","Type":"Episode",
         "Chapters":[{"StartPositionTicks":0,"Name":"Cold Open"},
                     {"StartPositionTicks":600000000,"Name":"Main Titles"}],
         "Trickplay":{"src1":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,
                                     "ThumbnailCount":120,"Interval":10000}}}}
        """
    }

    // MARK: - When a fetch is owed

    @Test("an item that was never asked for Chapters earns a detail fetch")
    func slimEpisodeNeedsEnrichment() throws {
        let item = try decodeItem(#"{"Id":"e1","Name":"E1","Type":"Episode"}"#)
        #expect(item.chapters == nil)
        #expect(PlayerViewModel.needsDetailEnrichment(item: item, isLive: false))
    }

    /// nil means "never requested", `[]` means "requested, genuinely none". Keeping them apart is what
    /// stops a chapterless file from paying for a round-trip on every single launch.
    @Test("an empty Chapters array is an answer, not a gap")
    func chapterlessFileIsNotRefetched() throws {
        let item = try decodeItem(#"{"Id":"m1","Name":"M1","Type":"Movie","Chapters":[]}"#)
        #expect(PlayerViewModel.needsDetailEnrichment(item: item, isLive: false) == false)
    }

    @Test("an item that already carries chapters is left alone")
    func detailItemNeedsNothing() throws {
        let item = try decodeItem(detailJSON)
        #expect(PlayerViewModel.needsDetailEnrichment(item: item, isLive: false) == false)
    }

    /// A live channel item is synthesised from the channel plus its EPG program; there is no library
    /// item behind it to fetch, and the live load path shows no chapter UI at all.
    @Test("a live session never fetches detail")
    func liveSessionNeverEnriches() throws {
        let item = try decodeItem(#"{"Id":"c1","Name":"C1","Type":"TvChannel"}"#)
        #expect(PlayerViewModel.needsDetailEnrichment(item: item, isLive: true) == false)
    }

    // MARK: - The merge

    @Test("the merge fills chapters and the trickplay manifest")
    func mergeFillsMissingFields() throws {
        var item = try decodeItem(#"{"Id":"e1","Name":"E1","Type":"Episode"}"#)
        item.applyDetailFields(from: try decodeItem(detailJSON))
        #expect(item.chapters?.count == 2)
        #expect(item.chapters?.first?.name == "Cold Open")
        #expect(item.trickplay?["src1"]?["320"]?.thumbnailCount == 120)
    }

    /// Additive on purpose: the launch item's `userData` holds the resume position this session is
    /// already playing from, and the detail response carries the server's staler copy of it.
    @Test("the merge leaves the session's resume position alone")
    func mergeKeepsUserData() throws {
        var item = try decodeItem(#"{"Id":"e1","Name":"E1","Type":"Episode","RunTimeTicks":10000}"#)
        item.setResumePosition(500)
        item.applyDetailFields(from: try decodeItem(detailJSON))
        #expect(item.userData?.playbackPositionTicks == 500)
        #expect(item.chapters?.count == 2)
    }

    /// An auto-advance swaps the item while the fetch for the previous episode is still in flight.
    @Test("a detail for a different item is ignored")
    func mergeRejectsForeignDetail() throws {
        var item = try decodeItem(#"{"Id":"e2","Name":"E2","Type":"Episode"}"#)
        item.applyDetailFields(from: try decodeItem(detailJSON))
        #expect(item.chapters == nil)
        #expect(item.trickplay == nil)
    }

    @Test("the merge does not overwrite fields the item already has")
    func mergeIsAdditive() throws {
        var item = try decodeItem(#"{"Id":"e1","Name":"E1","Type":"Episode","Chapters":[]}"#)
        item.applyDetailFields(from: try decodeItem(detailJSON))
        #expect(item.chapters?.isEmpty == true)
        #expect(item.trickplay?["src1"]?["320"] != nil)
    }

    // MARK: - Ordering

    /// Chapter image URLs index the server's original array, so the sort has to carry the original
    /// offsets alongside it. The API documents start-position order but legacy taggers emit otherwise.
    @Test("chapters sort by start position and keep their original indices")
    func chaptersSortWithIndices() throws {
        let item = try decodeItem("""
        {"Id":"e1","Name":"E1","Type":"Episode",
         "Chapters":[{"StartPositionTicks":600000000,"Name":"B"},
                     {"StartPositionTicks":0,"Name":"A"},
                     {"StartPositionTicks":1200000000,"Name":"C"}]}
        """)
        let ordered = PlayerViewModel.orderedChapters(from: item.chapters)
        #expect(ordered.chapters.map(\.name) == ["A", "B", "C"])
        #expect(ordered.imageIndices == [1, 0, 2])
    }

    @Test("no chapters yields empty arrays, not a crash")
    func orderingHandlesNil() {
        let ordered = PlayerViewModel.orderedChapters(from: nil)
        #expect(ordered.chapters.isEmpty)
        #expect(ordered.imageIndices.isEmpty)
    }
}
