import Foundation
import Testing
@testable import Sodalite

/// Sodalite#100: an ATSC 3.0 channel's AC-4 audio has no decoder anywhere in this stack, so the tune
/// used to sit in the tuning indicator until the viewer backed out. The refusal is a decision about
/// codec strings the server already handed us, so it is a pure function and these hold it.
///
/// The two spelling traps are the reason this is not a string comparison: Jellyfin copies a tuner
/// channel's audio codec verbatim out of the HDHomeRun's `lineup.json` (which reports "AC3", so
/// presumably "AC4"), while a probed source carries ffprobe's lowercase name, and the same tuner
/// channel reports index -1 for every stream.
@Suite("Live audio support")
struct LiveAudioSupportTests {

    private func stream(_ type: MediaStreamType, codec: String?, index: Int = -1) -> MediaStream {
        MediaStream(index: index, type: type, codec: codec, language: nil,
                    displayTitle: nil, title: nil, isDefault: nil, isForced: nil,
                    isExternal: nil, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    private func audio(_ codec: String?, index: Int = -1) -> MediaStream {
        stream(.audio, codec: codec, index: index)
    }

    // MARK: - Refusal

    @Test("an AC-4 only channel is refused")
    func ac4OnlyIsRefused() {
        #expect(LiveAudioSupport.verdict(for: [stream(.video, codec: "hevc"), audio("ac4")])
            == .noDecodableAudio(.ac4))
    }

    @Test("the tuner's own spelling is the one that actually arrives", arguments: [
        "AC4", "AC-4", "ac-4", "Ac4", " ac4 ",
    ])
    func tunerSpellingsMatch(_ codec: String) {
        #expect(LiveAudioSupport.verdict(for: [audio(codec)]) == .noDecodableAudio(.ac4))
    }

    @Test("every MPEG-H spelling is refused", arguments: [
        "mpegh_3d_audio", "MPEGH", "mpegh3da", "mhm1", "mha1",
    ])
    func mpeghSpellingsMatch(_ codec: String) {
        #expect(LiveAudioSupport.verdict(for: [audio(codec)]) == .noDecodableAudio(.mpegH))
    }

    @Test("several undecodable tracks are still one refusal, named after the first")
    func severalUndecodableTracks() {
        #expect(LiveAudioSupport.verdict(for: [audio("ac4", index: 1), audio("mhm1", index: 3)])
            == .noDecodableAudio(.ac4))
    }

    // MARK: - Proceeding, which is the default the denylist has to fall back to

    @Test("one decodable track beside AC-4 plays")
    func mixedTracksProceed() {
        #expect(LiveAudioSupport.verdict(for: [audio("ac4"), audio("ac3")]) == .mayHaveAudio)
    }

    @Test("a source that named no audio at all is the engine's call")
    func noAudioReported() {
        #expect(LiveAudioSupport.verdict(for: [stream(.video, codec: "hevc")]) == .noAudioReported)
        #expect(LiveAudioSupport.verdict(for: []) == .noAudioReported)
        #expect(LiveAudioSupport.verdict(for: nil) == .noAudioReported)
    }

    @Test("an empty or missing codec string is not a refusal", arguments: [nil, "", "   "])
    func emptyCodecProceeds(_ codec: String?) {
        #expect(LiveAudioSupport.verdict(for: [audio(codec)]) == .mayHaveAudio)
    }

    @Test("ordinary broadcast audio is untouched", arguments: [
        "ac3", "eac3", "aac", "mp2", "AC3", "aac_latm", "opus", "dts",
    ])
    func decodableCodecsProceed(_ codec: String) {
        #expect(LiveAudioSupport.verdict(for: [audio(codec)]) == .mayHaveAudio)
    }

    @Test("a codec nobody enumerated proceeds rather than being refused by omission")
    func unknownCodecProceeds() {
        #expect(LiveAudioSupport.verdict(for: [audio("some_future_codec")]) == .mayHaveAudio)
    }

    @Test("a video stream carrying an unplayable name is not an audio verdict")
    func videoStreamIsIgnored() {
        #expect(LiveAudioSupport.verdict(for: [stream(.video, codec: "ac4")]) == .noAudioReported)
    }

    // MARK: - The diagnostic line, which is what answers the next report

    @Test("the log line keeps the server's raw spelling and index")
    func logLineKeepsRawSpelling() {
        #expect(LiveAudioSupport.logLine(for: [stream(.video, codec: "hevc"), audio("AC4")])
            == "[Live] audio streams: -1=AC4 verdict=noDecodableAudio(AC-4)")
    }

    @Test("a probed source's indices survive")
    func logLineProbedIndices() {
        #expect(LiveAudioSupport.logLine(for: [audio("ac4", index: 1), audio("ac4", index: 3)])
            == "[Live] audio streams: 1=ac4 3=ac4 verdict=noDecodableAudio(AC-4)")
    }

    @Test("a channel the server said nothing about says so")
    func logLineNoAudio() {
        #expect(LiveAudioSupport.logLine(for: [stream(.video, codec: "hevc")])
            == "[Live] audio streams: none reported")
    }

    @Test("a healthy channel is logged as checked, not as silence")
    func logLineHealthy() {
        #expect(LiveAudioSupport.logLine(for: [audio("ac3", index: 1)])
            == "[Live] audio streams: 1=ac3 verdict=mayHaveAudio")
    }

    @Test("an empty codec is visible in the line rather than blank")
    func logLineEmptyCodec() {
        #expect(LiveAudioSupport.logLine(for: [audio(nil, index: 2)])
            == "[Live] audio streams: 2=? verdict=mayHaveAudio")
    }

    // MARK: - The sentence the viewer reads

    /// The format name is a `%@` argument, so a catalog key without the substitution would ship a
    /// message that names no codec at all.
    @Test("the refusal names the format it refused")
    func refusalNamesTheFormat() {
        let message = ErrorText.user(for: PlayerEngineError.liveAudioUnsupported(codec: "AC-4"))
        #expect(message.contains("AC-4"))
        #expect(!message.contains("%@"))
        #expect(message != ErrorText.unexpected)
    }

    @Test("both display names survive the round trip", arguments: [
        LiveAudioSupport.UnplayableCodec.ac4, .mpegH,
    ])
    func displayNamesReachTheMessage(_ codec: LiveAudioSupport.UnplayableCodec) {
        #expect(ErrorText.user(for: PlayerEngineError.liveAudioUnsupported(codec: codec.displayName))
            .contains(codec.displayName))
    }
}
