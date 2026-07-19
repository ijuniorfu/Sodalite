import Testing
import Foundation
import CoreGraphics
import AetherEngine
@testable import Sodalite

/// Disc-parity forced subtitles: with subtitles OFF, forced captions (signs, foreign dialogue)
/// still show, like a disc player or TV would. Two shapes, resolved in priority order:
/// a dedicated forced track (rendered whole), else a full/SDH BITMAP track matching the audio
/// language whose cues are filtered to the per-cue forced flag (AetherEngine 5.9.5, AE#146).
/// The selection is engine-silent: the picker keeps showing "Off", nothing is reported upstream.
@MainActor
struct ForcedSubtitleFallbackTests {

    private func stream(index: Int, codec: String? = "subrip", lang: String? = "en",
                        title: String? = nil, forced: Bool? = nil,
                        external: Bool = false) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: codec, language: lang,
                    displayTitle: nil, title: title, isDefault: nil, isForced: forced,
                    isExternal: external, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    // MARK: - Dedicated forced track (case 1)

    @Test("a forced track matching the audio language wins")
    func forcedTrackLanguageMatch() {
        let streams = [stream(index: 2, codec: "hdmv_pgs_subtitle", lang: "en"),
                       stream(index: 3, lang: "en", forced: true),
                       stream(index: 4, lang: "de", forced: true)]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "eng")
                == .forcedTrack(streamIndex: 3))
    }

    @Test("a 'forced' title marks a track forced even without the flag")
    func forcedByTitle() {
        let streams = [stream(index: 7, lang: "en", title: "English (Forced)")]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "en")
                == .forcedTrack(streamIndex: 7))
    }

    @Test("an untagged single forced track is used when no language-matched one exists")
    func untaggedSingleForcedTrack() {
        let streams = [stream(index: 2, codec: "hdmv_pgs_subtitle", lang: "en"),
                       stream(index: 5, lang: nil, forced: true)]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "en")
                == .forcedTrack(streamIndex: 5))
    }

    @Test("a single forced track in the WRONG language is not shown")
    func wrongLanguageForcedTrackSkipped() {
        let streams = [stream(index: 5, lang: "fr", forced: true)]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "en")
                == .none)
    }

    @Test("an external forced sidecar is eligible for the dedicated-track path")
    func externalForcedTrackEligible() {
        let streams = [stream(index: 9, lang: "en", forced: true, external: true)]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "en")
                == .forcedTrack(streamIndex: 9))
    }

    // MARK: - Cue-filter fallback on a full bitmap track (case 2, AE#146)

    @Test("no forced track: the language-matched full PGS track becomes the cue filter")
    func cueFilterOnFullBitmapTrack() {
        let streams = [stream(index: 2, codec: "subrip", lang: "en"),
                       stream(index: 3, codec: "hdmv_pgs_subtitle", lang: "en"),
                       stream(index: 4, codec: "hdmv_pgs_subtitle", lang: "de")]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "eng")
                == .cueFilter(streamIndex: 3))
    }

    @Test("text-only tracks offer no cue filter (per-cue forced exists only for bitmap)")
    func textOnlyNoCueFilter() {
        let streams = [stream(index: 2, codec: "subrip", lang: "en"),
                       stream(index: 3, codec: "ass", lang: "en")]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "en")
                == .none)
    }

    @Test("full beats SDH for the cue-filter track; signs/songs/commentary are excluded")
    func cueFilterRanking() {
        let streams = [stream(index: 2, codec: "hdmv_pgs_subtitle", lang: "en", title: "Signs & Songs"),
                       stream(index: 3, codec: "hdmv_pgs_subtitle", lang: "en", title: "English (SDH)"),
                       stream(index: 4, codec: "hdmv_pgs_subtitle", lang: "en")]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "en")
                == .cueFilter(streamIndex: 4))
        let signsOnly = [stream(index: 2, codec: "hdmv_pgs_subtitle", lang: "en", title: "Signs & Songs")]
        #expect(ForcedSubtitleFallback.resolve(streams: signsOnly, audioLanguage: "en")
                == .none)
    }

    @Test("an untagged single bitmap track is used when no language-matched one exists")
    func untaggedSingleBitmapTrack() {
        let streams = [stream(index: 3, codec: "hdmv_pgs_subtitle", lang: nil)]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "ja")
                == .cueFilter(streamIndex: 3))
    }

    @Test("an external bitmap track is not eligible for the cue filter")
    func externalBitmapNotEligible() {
        let streams = [stream(index: 9, codec: "hdmv_pgs_subtitle", lang: "en", external: true)]
        #expect(ForcedSubtitleFallback.resolve(streams: streams, audioLanguage: "en")
                == .none)
    }

    @Test("no subtitle streams resolve to none")
    func emptyStreams() {
        #expect(ForcedSubtitleFallback.resolve(streams: [], audioLanguage: "en") == .none)
    }

    // MARK: - Cue filtering

    private func imageCue(id: Int, forced: Bool) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleCue(id: id, startTime: 0, endTime: 5,
                           body: .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero,
                                                      isForced: forced)))
    }

    @Test("cueFilter mode keeps only forced cues; forcedTrack and none pass everything through")
    func cueFiltering() {
        let cues = [imageCue(id: 1, forced: true),
                    imageCue(id: 2, forced: false),
                    SubtitleCue(id: 3, startTime: 0, endTime: 5, body: .text("dialogue"))]
        let filtered = ForcedSubtitleFallback.filteredCues(cues, mode: .cueFilter(streamIndex: 3))
        #expect(filtered.map(\.id) == [1])
        #expect(ForcedSubtitleFallback.filteredCues(cues, mode: .forcedTrack(streamIndex: 3)).count == 3)
        #expect(ForcedSubtitleFallback.filteredCues(cues, mode: .none).count == 3)
    }
}
