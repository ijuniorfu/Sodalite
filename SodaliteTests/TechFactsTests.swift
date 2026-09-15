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

    /// An item with neither media nor catalogue metadata has nothing to caption and no section to
    /// draw. The page has to collapse both rather than paint an empty reader.
    @Test func anItemWithoutMediaOrMetadataSaysNothing() throws {
        let facts = TechFacts.resolve(item: try decode(#"{"Id":"s","Name":"S","Type":"Series"}"#), sourceID: nil)
        #expect(facts.isEmpty)
        #expect(facts.caption == nil)
    }

    // MARK: - What the title is, rather than what the file is (Sodalite#146 round 2)

    private static let seriesJSON = #"""
    {"Id":"series-1","Name":"Lost","Type":"Series","Status":"Ended",
     "PremiereDate":"2004-09-22T00:00:00.0000000Z","ChildCount":6,
     "Genres":["Drama","Mystery","Adventure"],
     "Studios":[{"Name":"ABC"},{"Name":"Bad Robot"},{"Name":"Touchstone"},{"Name":"Grass Skirt"}]}
    """#

    /// The reason the reader exists on a show at all. A series carries no media streams, so every
    /// other section is empty for it and More Details was the synopsis over again, which is what a
    /// reporter called redundant with the show screen.
    @Test func aSeriesRootStillHasSomethingToSay() throws {
        let facts = TechFacts.resolve(item: try decode(Self.seriesJSON), sourceID: nil)
        let about = try #require(facts.sections.first { $0.id == "about" })
        #expect(about.rows.map(\.id) == ["status", "premiere", "seasons", "genres", "studios"])
        #expect(about.rows.first { $0.id == "seasons" }?.value == "6")
        #expect(about.rows.first { $0.id == "genres" }?.value == "Drama, Mystery, Adventure")
    }

    /// It leads, because it describes the title and everything below it describes a file.
    @Test func whatTheTitleIsComesFirst() throws {
        let facts = TechFacts.resolve(item: try decode(Self.seriesJSON), sourceID: nil)
        #expect(facts.sections.first?.id == "about")
    }

    /// Jellyfin writes seven fractional digits, which ISO8601DateFormatter rejects at every setting,
    /// so only the day is parsed. The rendering is the viewer's locale, hence the year rather than a
    /// literal.
    @Test func thePremiereIsADateAndNotAServerTimestamp() throws {
        let facts = TechFacts.resolve(item: try decode(Self.seriesJSON), sourceID: nil)
        let premiere = try #require(facts.sections.first { $0.id == "about" }?
            .rows.first { $0.id == "premiere" }?.value)
        #expect(premiere.contains("2004"))
        #expect(!premiere.contains("T00:00"))
    }

    /// Three, the same cut the glass panel made. Past that it is a distributor list, not a credit.
    @Test func studiosStopAtThree() throws {
        let facts = TechFacts.resolve(item: try decode(Self.seriesJSON), sourceID: nil)
        let studios = try #require(facts.sections.first { $0.id == "about" }?
            .rows.first { $0.id == "studios" }?.value)
        #expect(studios == "ABC, Bad Robot, Touchstone")
    }

    /// A status the server invents is passed through rather than swallowed: an unknown word says
    /// more than a blank row.
    @Test func anUnknownStatusIsPassedThrough() throws {
        let json = #"{"Id":"s","Name":"S","Type":"Series","Status":"Unreleased"}"#
        let facts = TechFacts.resolve(item: try decode(json), sourceID: nil)
        let status = try #require(facts.sections.first { $0.id == "about" }?
            .rows.first { $0.id == "status" }?.value)
        #expect(status == "Unreleased")
    }

    /// Status, premiere and season count are a SERIES's facts. A movie gets the two rows that apply
    /// to it and no empty ones.
    @Test func aMovieGetsOnlyTheRowsThatApplyToIt() throws {
        let json = #"""
        {"Id":"m","Name":"M","Type":"Movie","Status":"Ended","ChildCount":3,
         "PremiereDate":"2017-10-04T00:00:00.0000000Z",
         "Genres":["Sci-Fi"],"Studios":[{"Name":"Warner Bros."}]}
        """#
        let facts = TechFacts.resolve(item: try decode(json), sourceID: nil)
        let about = try #require(facts.sections.first { $0.id == "about" })
        #expect(about.rows.map(\.id) == ["genres", "studios"])
    }
}
