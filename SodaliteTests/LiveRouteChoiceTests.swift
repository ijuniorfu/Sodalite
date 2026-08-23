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
}
