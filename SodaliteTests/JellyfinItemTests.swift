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
}
