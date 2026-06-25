import Testing
import Foundation
@testable import Sodalite

/// Small arithmetic/fallback units a refactor breaks silently: resume clamp (issue #24), tmdbID fallback chain, tick conversion.
@MainActor
struct JellyfinItemTests {
    private func decodeItem(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    @Test func setResumePositionComputesPercentageFromRuntime() throws {
        var item = try decodeItem(#"{"Id":"m","Name":"M","Type":"Movie","RunTimeTicks":1000}"#)
        item.setResumePosition(500)
        #expect(item.userData?.playbackPositionTicks == 500)
        #expect(item.userData?.playedPercentage == 50)
    }

    @Test func setResumePositionClampsAtHundred() throws {
        var item = try decodeItem(#"{"Id":"m","Name":"M","Type":"Movie","RunTimeTicks":1000}"#)
        item.setResumePosition(5000)
        #expect(item.userData?.playedPercentage == 100)
    }

    @Test func setResumePositionWithZeroRuntimeDoesNotDivide() throws {
        var item = try decodeItem(#"{"Id":"m","Name":"M","Type":"Movie","RunTimeTicks":0}"#)
        item.setResumePosition(500)
        #expect(item.userData?.playbackPositionTicks == 500)
        #expect(item.userData?.playedPercentage == nil)
    }

    @Test func setResumePositionWithNilRuntimeKeepsPercentageNil() {
        var item = JellyfinItem(seriesStub: "s", name: "S")
        item.setResumePosition(500)
        #expect(item.userData?.playbackPositionTicks == 500)
        #expect(item.userData?.playedPercentage == nil)
    }

    @Test func tmdbIDReadsCaseVariantKeys() throws {
        #expect(try decodeItem(#"{"Id":"a","Name":"A","Type":"Movie","ProviderIds":{"Tmdb":"603"}}"#).tmdbID == 603)
        #expect(try decodeItem(#"{"Id":"a","Name":"A","Type":"Movie","ProviderIds":{"tmdb":"55"}}"#).tmdbID == 55)
        #expect(try decodeItem(#"{"Id":"a","Name":"A","Type":"Movie","ProviderIds":{"TMDB":"7"}}"#).tmdbID == 7)
    }

    @Test func tmdbIDIsNilWhenMissingOrNonNumeric() throws {
        #expect(try decodeItem(#"{"Id":"a","Name":"A","Type":"Movie"}"#).tmdbID == nil)
        #expect(try decodeItem(#"{"Id":"a","Name":"A","Type":"Movie","ProviderIds":{"Tmdb":"abc"}}"#).tmdbID == nil)
    }

    @Test func unknownItemTypeDecodesToUnknown() throws {
        #expect(try decodeItem(#"{"Id":"a","Name":"A","Type":"Hologram"}"#).type == .unknown)
    }

    @Test func chapterStartSecondsConvertsTicks() {
        #expect(ChapterInfo(startPositionTicks: 10_000_000, name: nil, imageTag: nil).startSeconds == 1.0)
    }

    @Test func decodesTrickplayManifest() throws {
        let item = try decodeItem(#"""
        {"Id":"abc","Name":"X","Type":"Movie",
         "Trickplay":{"src1":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,
                      "ThumbnailCount":240,"Interval":10000,"Bandwidth":1000}}}}
        """#)
        let info = try #require(item.trickplay?["src1"]?["320"])
        #expect(info.width == 320)
        #expect(info.tileWidth == 10)
        #expect(info.tileHeight == 10)
        #expect(info.thumbnailCount == 240)
        #expect(info.interval == 10000)
    }
}
