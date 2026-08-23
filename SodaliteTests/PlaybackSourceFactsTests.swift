import Testing
import Foundation
@testable import Sodalite

/// The stats panel used to describe the media from `item.mediaSources`, which is a description the launch
/// item does not always carry. Episode rows come from a list query whose fields do not include
/// `MediaSources` or `MediaStreams`; movies come from a detail fetch whose fields do. Same library, same
/// panel, and one of them rendered without video, subtitle or file sections.
///
/// The session's own PlaybackInfo source is the answer to that: the player already holds it, it names the
/// version actually playing, and it exists on every path except the remembered-URL live shortcut.
@MainActor
struct PlaybackSourceFactsTests {

    // MARK: - Payloads, in the two shapes the server really sends

    /// A list-shaped episode: what `JellyfinItemService` returns for a season listing or Next Up. No
    /// MediaSources, no MediaStreams, which is the entire defect.
    private static let slimEpisodeJSON = """
    {"Id":"ep1","Name":"Episode 1","Type":"Episode"}
    """

    /// A detail-shaped movie, fetched with `detailFields`.
    private static let detailMovieJSON = """
    {"Id":"mv1","Name":"Movie","Type":"Movie",
     "MediaSources":[{"Id":"src-a","Path":"/media/Movies/Movie/Movie.mkv","Container":"mkv",
       "Size":8000000000,"Bitrate":12000000,
       "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]}]}
    """

    private func decodeItem(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func sessionSource(
        id: String = "src-live",
        path: String? = "/var/lib/jellyfin/transcodes/abc.ts",
        container: String? = "ts",
        size: Int64? = nil,
        bitrate: Int? = 4_000_000,
        streams: [MediaStream]? = nil
    ) -> PlaybackMediaSource {
        PlaybackMediaSource(
            id: id, name: nil, path: path, container: container, size: size, bitrate: bitrate,
            supportsDirectPlay: nil, supportsDirectStream: nil, supportsTranscoding: nil,
            transcodingUrl: nil, mediaStreams: streams, liveStreamId: nil, transcodeReasons: nil)
    }

    private func videoStream(codec: String, width: Int, height: Int) -> MediaStream {
        MediaStream(
            index: 0, type: .video, codec: codec, language: nil, displayTitle: nil, title: nil,
            isDefault: nil, isForced: nil, isExternal: nil, height: height, width: width,
            channels: nil, videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
            realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    // MARK: - The defect

    @Test("a slim episode describes itself through the session's source")
    func slimItemBorrowsTheSessionSource() throws {
        let item = try decodeItem(Self.slimEpisodeJSON)
        let facts = PlaybackSourceFacts.resolve(
            session: sessionSource(
                path: "/media/Shows/Show/S01E01.mkv", container: "mkv", size: 2_000_000_000,
                streams: [videoStream(codec: "h264", width: 1920, height: 1080)]),
            item: item,
            selectedMediaSourceID: "src-live")

        #expect(facts.container == "mkv")
        #expect(facts.sizeBytes == 2_000_000_000)
        #expect(facts.path == "/media/Shows/Show/S01E01.mkv")
        #expect(facts.streams.count == 1)
        #expect(facts.streams.first?.codec == "h264")
    }

    @Test("with no session source a slim episode still has nothing, and says so")
    func slimItemWithoutSessionSourceStaysEmpty() throws {
        let item = try decodeItem(Self.slimEpisodeJSON)
        let facts = PlaybackSourceFacts.resolve(session: nil, item: item, selectedMediaSourceID: nil)
        #expect(facts.container == nil)
        #expect(facts.path == nil)
        #expect(facts.streams.isEmpty)
        #expect(!facts.hasAny)
    }

    // MARK: - Not at the cost of the path that already worked

    @Test("a detail item still describes itself when no session source exists yet")
    func detailItemAnswersOnItsOwn() throws {
        let item = try decodeItem(Self.detailMovieJSON)
        let facts = PlaybackSourceFacts.resolve(session: nil, item: item, selectedMediaSourceID: "src-a")
        #expect(facts.container == "mkv")
        #expect(facts.sizeBytes == 8_000_000_000)
        #expect(facts.bitrate == 12_000_000)
        #expect(facts.streams.first?.codec == "hevc")
        #expect(facts.hasAny)
    }

    /// The session and the item describe the same file here, so this is only about which one is asked
    /// first. The session wins because it names the version that is playing rather than the first one
    /// listed, which is the multi-version case (issue #37) the id resolution already exists for.
    @Test("the session's source outranks the item's when both are present")
    func sessionOutranksItem() throws {
        let item = try decodeItem(Self.detailMovieJSON)
        let facts = PlaybackSourceFacts.resolve(
            session: sessionSource(
                id: "src-b", path: "/media/Movies/Movie/Movie 1080p.mkv", container: "mkv",
                size: 4_000_000_000, bitrate: 6_000_000,
                streams: [videoStream(codec: "h264", width: 1920, height: 1080)]),
            item: item,
            selectedMediaSourceID: "src-b")
        #expect(facts.path == "/media/Movies/Movie/Movie 1080p.mkv")
        #expect(facts.sizeBytes == 4_000_000_000)
        #expect(facts.streams.first?.width == 1920)
    }

    /// A live source names a tuner path and no size at all. Falling back field by field lets the item fill
    /// what the session leaves nil, which is what keeps a thin live source from blanking a row the item
    /// could have answered.
    @Test("a field the session leaves nil falls back to the item")
    func fieldLevelFallback() throws {
        let item = try decodeItem(Self.detailMovieJSON)
        let facts = PlaybackSourceFacts.resolve(
            session: sessionSource(id: "src-a", path: nil, container: nil, size: nil, bitrate: nil,
                                   streams: nil),
            item: item,
            selectedMediaSourceID: "src-a")
        #expect(facts.container == "mkv")
        #expect(facts.sizeBytes == 8_000_000_000)
        #expect(facts.streams.first?.codec == "hevc")
    }

    // MARK: - Filename

    @Test("the filename is the last path component, not the whole server path")
    func filenameFromPath() throws {
        let facts = PlaybackSourceFacts.resolve(
            session: sessionSource(path: "/media/Shows/Show/Season 01/S01E01 Pilot.mkv"),
            item: try decodeItem(Self.slimEpisodeJSON),
            selectedMediaSourceID: nil)
        #expect(facts.fileName == "S01E01 Pilot.mkv")
    }

    @Test("a path that is not a path yields no filename")
    func filenameFromEmptyPath() throws {
        let facts = PlaybackSourceFacts.resolve(
            session: sessionSource(path: ""),
            item: try decodeItem(Self.slimEpisodeJSON),
            selectedMediaSourceID: nil)
        #expect(facts.fileName == nil)
    }
}
