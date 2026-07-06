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

    // MARK: - Multi-version source resolution (issue #37)

    /// Two versions: primary (item-level + first source) is AV1, second is HEVC/x265.
    private static let multiVersionJSON = #"""
    {"Id":"m","Name":"TRON","Type":"Movie",
     "MediaStreams":[{"Index":0,"Type":"Video","Codec":"av1"}],
     "MediaSources":[
       {"Id":"srcAV1","Name":"AV1","Container":"mp4","MediaStreams":[{"Index":0,"Type":"Video","Codec":"av1"}]},
       {"Id":"srcX265","Name":"x265","Container":"mkv","MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc"}]}
     ]}
    """#

    @Test func effectiveSourceResolvesPickedVersionNotFirst() throws {
        let item = try decodeItem(Self.multiVersionJSON)
        let source = try #require(item.effectiveMediaSource(id: "srcX265"))
        #expect(source.id == "srcX265")
        #expect(source.primaryVideoStream?.codec == "hevc")
    }

    @Test func effectiveSourceFallsBackToFirstForNilEmptyOrUnmatchedID() throws {
        let item = try decodeItem(Self.multiVersionJSON)
        for id in [nil, "", "does-not-exist"] as [String?] {
            #expect(item.effectiveMediaSource(id: id)?.id == "srcAV1")
        }
    }

    @Test func effectiveStreamsReflectPickedVersion() throws {
        let item = try decodeItem(Self.multiVersionJSON)
        let streams = try #require(item.effectiveMediaStreams(id: "srcX265"))
        #expect(streams.first(where: { $0.type == .video })?.codec == "hevc")
    }

    @Test func effectiveStreamsFallBackToItemLevelWhenSourceCarriesNone() throws {
        let item = try decodeItem(#"""
        {"Id":"m","Name":"M","Type":"Movie",
         "MediaStreams":[{"Index":0,"Type":"Video","Codec":"av1"}],
         "MediaSources":[{"Id":"only","Name":"Only"}]}
        """#)
        let streams = try #require(item.effectiveMediaStreams(id: "only"))
        #expect(streams.first(where: { $0.type == .video })?.codec == "av1")
    }

    @Test func effectiveSourceReturnsLoneSourceRegardlessOfID() throws {
        let item = try decodeItem(#"""
        {"Id":"m","Name":"M","Type":"Movie",
         "MediaSources":[{"Id":"only","Name":"Only","MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc"}]}]}
        """#)
        #expect(item.effectiveMediaSource(id: "whatever")?.id == "only")
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
