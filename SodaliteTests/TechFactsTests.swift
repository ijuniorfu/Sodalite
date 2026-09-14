import Testing
import Foundation
import SwiftUI
@testable import Sodalite

/// Sodalite#146 moved the four-card tech strip off the page and into More Details plus a one-line
/// caption. The extraction is the part worth pinning: the strip could only ever show one audio track
/// and four subtitles, and both surfaces now have to describe the version the viewer picked.
struct TechFactsTests {

    private func decode(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private static let movieJSON = #"""
    {"Id":"movie-1","Name":"Blade Runner 2049","Type":"Movie",
     "MediaSources":[
       {"Id":"src","Path":"/media/movies/Blade.Runner.2049.mkv","Container":"mkv",
        "Size":6012954214,"Bitrate":28900000,
        "MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","Profile":"Main 10","Width":3840,"Height":2160,
           "VideoRangeType":"HDR10","RealFrameRate":23.976},
          {"Index":1,"Type":"Audio","Codec":"flac","Channels":6,"DisplayTitle":"English FLAC 5.1"},
          {"Index":2,"Type":"Audio","Codec":"ac3","Channels":2,"Language":"deu"},
          {"Index":3,"Type":"Subtitle","Language":"eng"},
          {"Index":4,"Type":"Subtitle","Language":"dan","IsForced":true},
          {"Index":5,"Type":"Subtitle","Language":"fin"},
          {"Index":6,"Type":"Subtitle","Language":"swe"},
          {"Index":7,"Type":"Subtitle","Language":"nor"}
        ]}
     ]}
    """#

    /// filename, size, video codec, audio codec and layout, bitrate. One line, in that order.
    @Test func theCaptionNamesTheFile() throws {
        let facts = TechFacts.resolve(item: try decode(Self.movieJSON), sourceID: nil)
        #expect(facts.caption == "Blade.Runner.2049.mkv · 5.6 GB · HEVC · FLAC 5.1 · 28.9 Mbps")
    }

    /// Every audio track, where the strip showed the first and a count. Which languages a file
    /// carries is the question a track list answers.
    @Test func everyAudioTrackGetsARow() throws {
        let facts = TechFacts.resolve(item: try decode(Self.movieJSON), sourceID: nil)
        let audio = try #require(facts.sections.first { $0.id == "audio" })
        #expect(audio.rows.count == 2)
        #expect(audio.rows[0].label == .verbatim("English FLAC 5.1"))
        #expect(audio.rows[0].value == "FLAC · 5.1")
        #expect(audio.rows[1].label == .verbatim("deu"))
    }

    /// The whole subtitle list, where the strip stopped at four, with the forced flag surviving.
    @Test func everySubtitleTrackGetsARowAndForcedIsMarked() throws {
        let facts = TechFacts.resolve(item: try decode(Self.movieJSON), sourceID: nil)
        let subs = try #require(facts.sections.first { $0.id == "subtitles" })
        #expect(subs.rows.count == 5)
        #expect(subs.rows[1].label == .verbatim("dan"))
        #expect(!subs.rows[1].value.isEmpty)
        #expect(subs.rows[0].value.isEmpty)
    }

    /// A track name written into the file is already in the language the muxer chose, so it is never
    /// looked up in the catalog; a fixed label always is.
    @Test func trackNamesAreVerbatimAndFixedLabelsAreKeys() throws {
        let facts = TechFacts.resolve(item: try decode(Self.movieJSON), sourceID: nil)
        let video = try #require(facts.sections.first { $0.id == "video" })
        #expect(video.rows.contains { $0.label == .key("detail.tech.resolution") && $0.value == "3840×2160" })
        #expect(video.rows.contains { $0.label == .key("detail.tech.dynamicRange") && $0.value == "HDR10" })
    }

    /// Sodalite#139 one row further down: a two-version item used to strand the strip on its first
    /// source and say 1080p while the viewer had picked the 4K. Both surfaces read the selection now,
    /// so both inherit that bug unless the selection reaches them.
    @Test func theFactsFollowTheSelectedVersion() throws {
        let item = try decode(#"""
        {"Id":"m","Name":"M","Type":"Movie",
         "MediaSources":[
           {"Id":"hd","Path":"/media/M.1080p.mkv","Container":"mkv","Size":5000000000,"Bitrate":8000000,
            "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]},
           {"Id":"uhd","Path":"/media/M.2160p.mkv","Container":"mkv","Size":40000000000,"Bitrate":60000000,
            "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]}
         ]}
        """#)
        let hd = TechFacts.resolve(item: item, sourceID: "hd")
        let uhd = TechFacts.resolve(item: item, sourceID: "uhd")
        #expect(hd.caption?.contains("M.1080p.mkv") == true)
        #expect(uhd.caption?.contains("M.2160p.mkv") == true)
        #expect(hd != uhd)
    }

    /// A series root carries no media of its own, so there is nothing to caption and no section to
    /// draw. The page has to collapse both rather than paint an empty reader.
    @Test func anItemWithoutMediaSaysNothing() throws {
        let facts = TechFacts.resolve(item: try decode(#"{"Id":"s","Name":"S","Type":"Series"}"#), sourceID: nil)
        #expect(facts.isEmpty)
        #expect(facts.caption == nil)
    }
}
