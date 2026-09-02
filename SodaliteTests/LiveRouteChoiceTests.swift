import Foundation
import Testing
@testable import Sodalite

/// Sodalite#70, second round: the reporter's build entered the HLS direct ingest with Jellyfin's own
/// tuner-file URL, failed there, and fell back onto the copy-remux the issue exists to remove. Both
/// decisions used to be observable only as a log line on a device, which is why a whole retest round
/// went by without either one being visible. They are pure functions now, and these hold them.
@Suite("Live route choice")
@MainActor
struct LiveRouteChoiceTests {

    private let tunerPath = "http://192.168.1.50:8096/LiveTv/LiveStreamFiles/8a26baf2/stream.ts"
    private let providerPath = "https://iptv.example/live/user/pass/42.m3u8"
    private let transcodeURL = URL(string: "https://jf.example/videos/1/master.m3u8")!
    private let tunerFileURL = URL(string: "https://jf.example/LiveTv/LiveStreamFiles/8a26baf2/stream.ts")!
    private let staticURL = URL(string: "https://jf.example/Videos/1/stream.ts?Static=true")!

    // MARK: - Direct ingest eligibility

    @Test("Jellyfin's own tuner file never goes to the HLS ingest, TranscodingUrl or not")
    func tunerFileIsNotAnUpstream() {
        #expect(PlayerViewModel.liveDirectIngestEligibility(
            transcodingURL: "/videos/1/master.m3u8", sourcePath: tunerPath) == .pathIsJellyfinTunerFile)
    }

    @Test("a provider playlist on a remux channel is eligible")
    func providerPlaylistIsEligible() {
        #expect(PlayerViewModel.liveDirectIngestEligibility(
            transcodingURL: "/videos/1/master.m3u8", sourcePath: providerPath)
            == .eligible(URL(string: providerPath)!))
    }

    @Test("no TranscodingUrl is not a remux channel")
    func noTranscodingURL() {
        #expect(PlayerViewModel.liveDirectIngestEligibility(
            transcodingURL: nil, sourcePath: providerPath) == .notARemuxChannel)
    }

    @Test("a path that is not an http(s) URL is not an upstream")
    func nonHTTPPath() {
        #expect(PlayerViewModel.liveDirectIngestEligibility(
            transcodingURL: "/videos/1/master.m3u8", sourcePath: "/media/tv/channel.ts")
            == .pathNotAnUpstreamURL)
        #expect(PlayerViewModel.liveDirectIngestEligibility(
            transcodingURL: "/videos/1/master.m3u8", sourcePath: nil) == .pathNotAnUpstreamURL)
    }

    @Test("every ineligibility names itself, so the HUD line says which one happened")
    func reasonsAreDistinct() {
        let reasons = [
            PlayerViewModel.LiveDirectEligibility.notARemuxChannel.logReason,
            PlayerViewModel.LiveDirectEligibility.pathIsJellyfinTunerFile.logReason,
            PlayerViewModel.LiveDirectEligibility.pathNotAnUpstreamURL.logReason,
        ]
        #expect(Set(reasons).count == reasons.count)
    }

    // MARK: - Server route ranking

    @Test("a copy-remux TranscodingUrl loses to the tuner file it would have copied")
    func tunerFileBeatsCopyRemux() {
        #expect(PlayerViewModel.chooseLiveServerRoute(
            transcodeURL: transcodeURL, tunerFileURL: tunerFileURL, staticURL: staticURL,
            transcodeIsReencode: false) == .tunerFile(tunerFileURL))
    }

    @Test("a real re-encode wins: the engine cannot get that stream from the tuner file")
    func reencodeBeatsTunerFile() {
        #expect(PlayerViewModel.chooseLiveServerRoute(
            transcodeURL: transcodeURL, tunerFileURL: tunerFileURL, staticURL: staticURL,
            transcodeIsReencode: true) == .transcode(transcodeURL))
    }

    @Test("with the tuner file abandoned, the copy-remux is still preferred over static")
    func retreatPrefersTranscode() {
        #expect(PlayerViewModel.chooseLiveServerRoute(
            transcodeURL: transcodeURL, tunerFileURL: nil, staticURL: staticURL,
            transcodeIsReencode: false) == .transcode(transcodeURL))
    }

    @Test("a channel with neither transcode nor tuner file takes the static route")
    func staticIsTheFallback() {
        #expect(PlayerViewModel.chooseLiveServerRoute(
            transcodeURL: nil, tunerFileURL: nil, staticURL: staticURL,
            transcodeIsReencode: false) == .staticStream(staticURL))
    }

    @Test("a tuner channel with no TranscodingUrl and no static support still reads the tuner file")
    func tunerFileWithoutAnyServerRoute() {
        #expect(PlayerViewModel.chooseLiveServerRoute(
            transcodeURL: nil, tunerFileURL: tunerFileURL, staticURL: nil,
            transcodeIsReencode: false) == .tunerFile(tunerFileURL))
    }

    @Test("nothing offered is nothing to play")
    func noRouteAtAll() {
        #expect(PlayerViewModel.chooseLiveServerRoute(
            transcodeURL: nil, tunerFileURL: nil, staticURL: nil, transcodeIsReencode: false) == nil)
    }

    // MARK: - Which transcode reasons make an answer a real re-encode (#100 follow-up)

    private func url(_ reasons: String) -> String {
        "/videos/1/master.m3u8?TranscodeReasons=\(reasons)&api_key=x"
    }

    @Test("the reasons are read from the field and the URL, since neither is reliable alone")
    func reasonsComeFromBothPlaces() {
        #expect(PlayerViewModel.liveTranscodeReasons(
            transcodeReasons: ["AudioCodecNotSupported"], transcodingURL: url("VideoCodecNotSupported"))
            == ["AudioCodecNotSupported", "VideoCodecNotSupported"])
        #expect(PlayerViewModel.liveTranscodeReasons(
            transcodeReasons: nil, transcodingURL: url("ContainerNotSupported"))
            == ["ContainerNotSupported"])
        #expect(PlayerViewModel.liveTranscodeReasons(
            transcodeReasons: nil, transcodingURL: nil).isEmpty)
    }

    /// An audio-only mismatch is a real re-encode for the ROUTE: the tuner file carries the original
    /// audio, which is the one thing the server was told we cannot play.
    @Test("an audio codec the server cannot copy makes the TranscodingUrl worth taking")
    func audioReasonIsARealReencode() {
        #expect(PlayerViewModel.liveTranscodeIsRealReencode(
            transcodeReasons: ["AudioCodecNotSupported"], transcodingURL: nil))
        #expect(PlayerViewModel.liveTranscodeIsRealReencode(
            transcodeReasons: nil, transcodingURL: url("AudioCodecNotSupported")))
        #expect(PlayerViewModel.liveTranscodeIsRealReencode(
            transcodeReasons: ["VideoCodecNotSupported"], transcodingURL: nil))
    }

    /// The guard on the split. The bitrate re-negotiation re-requests the whole source at a 12 Mbps
    /// 1080p video target, so letting an audio-only reason reach it would push a 20 Mbps HEVC
    /// broadcast through a video encode for the sake of its soundtrack.
    @Test("an audio-only mismatch never triggers the bitrate re-negotiation")
    func audioReasonIsNotAVideoReencode() {
        #expect(!PlayerViewModel.liveNeedsVideoReencode(
            transcodeReasons: ["AudioCodecNotSupported"], transcodingURL: nil))
        #expect(!PlayerViewModel.liveNeedsVideoReencode(
            transcodeReasons: nil, transcodingURL: url("AudioCodecNotSupported")))
        #expect(PlayerViewModel.liveNeedsVideoReencode(
            transcodeReasons: nil, transcodingURL: url("AudioCodecNotSupported,VideoCodecNotSupported")))
    }

    @Test("a reason that is neither codec keeps the copy-remux ranking", arguments: [
        "ContainerNotSupported", "ContainerBitrateExceedsLimit", "SubtitleCodecNotSupported",
        "AudioChannelsNotSupported",
    ])
    func unrelatedReasonsAreStillACopy(_ reason: String) {
        #expect(!PlayerViewModel.liveTranscodeIsRealReencode(
            transcodeReasons: [reason], transcodingURL: url(reason)))
    }

    @Test("an audio-only re-encode now beats the tuner file it used to lose to")
    func audioReencodeWinsTheRoute() {
        let isReencode = PlayerViewModel.liveTranscodeIsRealReencode(
            transcodeReasons: ["AudioCodecNotSupported"], transcodingURL: nil)
        #expect(PlayerViewModel.chooseLiveServerRoute(
            transcodeURL: transcodeURL, tunerFileURL: tunerFileURL, staticURL: staticURL,
            transcodeIsReencode: isReencode) == .transcode(transcodeURL))
    }
}
