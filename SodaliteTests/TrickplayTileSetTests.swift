import Testing
import CoreGraphics
@testable import Sodalite

struct TrickplayTileSetTests {
    private func info(tileW: Int = 10, tileH: Int = 10, count: Int = 240) -> TrickplayInfo {
        TrickplayInfo(width: 320, height: 180, tileWidth: tileW, tileHeight: tileH,
                      thumbnailCount: count, interval: 10000, bandwidth: nil)
    }

    @Test("picks the rendition width closest to the target")
    func picksClosestWidth() throws {
        let map = ["src": ["160": info(), "320": info(), "640": info()]]
        let set = try #require(TrickplayTileSet(trickplay: map, mediaSourceID: "src", targetWidth: 320))
        #expect(set.width == 320)
    }

    @Test("first thumbnail is the top-left cell of tile 0")
    func firstThumb() throws {
        let set = try #require(TrickplayTileSet(trickplay: ["s": ["320": info()]], mediaSourceID: "s", targetWidth: 320))
        let t = try #require(set.tile(forSeconds: 0))
        #expect(t.tileIndex == 0)
        #expect(t.crop == CGRect(x: 0, y: 0, width: 320, height: 180))
    }

    @Test("thumbnail index maps to the right cell and tile")
    func cellWrap() throws {
        // interval 10s, tile 10x10 = 100 thumbs/tile. t=1005s -> thumb 100 -> tile 1, cell 0.
        let set = try #require(TrickplayTileSet(trickplay: ["s": ["320": info()]], mediaSourceID: "s", targetWidth: 320))
        let t = try #require(set.tile(forSeconds: 1005))
        #expect(t.tileIndex == 1)
        #expect(t.crop == CGRect(x: 0, y: 0, width: 320, height: 180))
        // t=15s -> thumb 1 -> tile 0, cell (col 1, row 0)
        let t2 = try #require(set.tile(forSeconds: 15))
        #expect(t2.tileIndex == 0)
        #expect(t2.crop == CGRect(x: 320, y: 0, width: 320, height: 180))
        // t=115s -> thumb 11 -> tile 0, cell (col 1, row 1)
        let t3 = try #require(set.tile(forSeconds: 115))
        #expect(t3.crop == CGRect(x: 320, y: 180, width: 320, height: 180))
    }

    @Test("clamps to the last thumbnail and returns nil for no rendition")
    func clampAndNil() throws {
        let set = try #require(TrickplayTileSet(trickplay: ["s": ["320": info(count: 5)]], mediaSourceID: "s", targetWidth: 320))
        let t = try #require(set.tile(forSeconds: 99999))   // way past 5 thumbs
        #expect(t.tileIndex == 0)                            // thumb clamped to 4 -> still tile 0
        #expect(TrickplayTileSet(trickplay: nil, mediaSourceID: "s", targetWidth: 320) == nil)
        #expect(TrickplayTileSet(trickplay: ["s": [:]], mediaSourceID: "s", targetWidth: 320) == nil)
    }
}
