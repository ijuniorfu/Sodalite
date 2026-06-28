import Testing
@testable import Sodalite

/// #68: Sodalite caps the engine's open-time routing-probe budget for SIZED server-file direct-play /
/// direct-stream sources (original container, sparse PGS tail), never for transcode. #31: live / infinite /
/// external-URL sources (a remote .strm IPTV stream, size == nil or an http path) are exempt, because the
/// cap truncates their continuous probe and crashes the load.
struct ProbeBudgetTests {

    private static func source(size: Int64?, path: String?) -> PlaybackMediaSource {
        PlaybackMediaSource(id: "x", name: nil, path: path, container: "mkv", size: size, bitrate: nil,
                            supportsDirectPlay: true, supportsDirectStream: true, supportsTranscoding: true,
                            transcodingUrl: nil, mediaStreams: nil, liveStreamId: nil, transcodeReasons: nil)
    }
    private static let sizedFile = Self.source(size: 1_000_000_000, path: "/media/movie.mkv")

    @Test("direct play caps the budget for a sized server file")
    func directPlayCapsBudget() {
        let b = PlayerViewModel.remoteDirectPlayProbeBudget(method: .directPlay, source: Self.sizedFile)
        #expect(b.probesize != nil)
        #expect(b.maxAnalyzeDuration != nil)
        // Under the engine default (50 MB / 60 s) to be a win, above audio's early-resolve needs.
        #expect(b.probesize! < 50 * 1024 * 1024)
        #expect(b.probesize! >= 8 * 1024 * 1024)
        #expect(b.maxAnalyzeDuration! < 60 * 1_000_000)
    }

    @Test("direct stream caps the budget for a sized server file")
    func directStreamCapsBudget() {
        let b = PlayerViewModel.remoteDirectPlayProbeBudget(method: .directStream, source: Self.sizedFile)
        #expect(b.probesize != nil)
        #expect(b.maxAnalyzeDuration != nil)
    }

    @Test("transcode keeps the engine default (no cap)")
    func transcodeKeepsDefault() {
        let b = PlayerViewModel.remoteDirectPlayProbeBudget(method: .transcode, source: Self.sizedFile)
        #expect(b.probesize == nil)
        #expect(b.maxAnalyzeDuration == nil)
    }

    @Test("size-less live source is exempt from the cap (#31)")
    func sizelessLiveSourceUncapped() {
        let live = Self.source(size: nil, path: "/media/channel.strm")
        let b = PlayerViewModel.remoteDirectPlayProbeBudget(method: .directPlay, source: live)
        #expect(b.probesize == nil)
        #expect(b.maxAnalyzeDuration == nil)
    }

    @Test("external http-URL source is exempt from the cap (#31)")
    func httpURLSourceUncapped() {
        let iptv = Self.source(size: 1234, path: "http://iptv.example/live/stream.ts")
        let b = PlayerViewModel.remoteDirectPlayProbeBudget(method: .directPlay, source: iptv)
        #expect(b.probesize == nil)
        #expect(b.maxAnalyzeDuration == nil)
    }
}
