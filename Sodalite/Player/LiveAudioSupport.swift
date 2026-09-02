import Foundation

/// Whether a live source's audio can reach a speaker at all, decided from the codec strings the
/// server named rather than from opening the stream (Sodalite#100).
///
/// An ATSC 3.0 channel carries AC-4, and nothing in this stack decodes it: FFmpeg has no AC-4
/// decoder (the patches have sat unmerged for years, partly because the format is Dolby
/// patent-encumbered), and tvOS has no AC-4 format constant either, so the native path cannot take
/// it. `find_stream_info` therefore never resolves the stream and burns its whole 60 s budget
/// before failing open with the track missing, which the viewer sees as a tuning indicator that
/// never stops. Refusing up front turns that into a sentence.
///
/// The codec string costs nothing to read: Jellyfin's `HdHomerunHost` builds the channel's
/// `MediaStream` list without opening a tuner and copies the audio codec straight out of the
/// tuner's `lineup.json`, so it is already in the PlaybackInfo answer the live load awaits. That
/// also means the spelling is the TUNER's, not ffprobe's ("AC3" is what an HDHomeRun reports), so
/// nothing here may compare raw strings.
enum LiveAudioSupport {

    /// An audio format no decoder on this device can turn into sound.
    ///
    /// Deliberately a denylist, not an allowlist of what plays: a codec nobody enumerated has to
    /// reach the engine and get its say, never be refused by omission.
    enum UnplayableCodec: Equatable {
        case ac4
        case mpegH

        /// Jellyfin can name the same format several ways depending on whether the string came from
        /// a tuner lineup, ffprobe, or an MP4 sample entry. All spellings are normalized.
        static func matching(_ codec: String) -> UnplayableCodec? {
            switch normalize(codec) {
            case "ac4": return .ac4
            case "mpegh", "mpegh3daudio", "mpegh3da", "mhm1", "mha1": return .mpegH
            default: return nil
            }
        }

        /// The name to say to the viewer. Not localized: these are format names, identical in every
        /// language, and the one in the message is what a search for the channel turns up.
        var displayName: String {
            switch self {
            case .ac4: return "AC-4"
            case .mpegH: return "MPEG-H 3D Audio"
            }
        }
    }

    /// What the server's audio codec strings say about this source's chances.
    enum Verdict: Equatable {
        /// No audio stream was named at all. The server told us nothing, so the engine decides.
        case noAudioReported
        /// At least one track carries a codec that is not on the denylist, including a track whose
        /// codec string is empty. Something may still produce sound, so the tune proceeds.
        case mayHaveAudio
        /// Every named audio track is a format nothing here decodes.
        case noDecodableAudio(UnplayableCodec)
    }

    static func verdict(for streams: [MediaStream]?) -> Verdict {
        let audio = (streams ?? []).filter { $0.type == .audio }
        guard !audio.isEmpty else { return .noAudioReported }

        var unplayable: [UnplayableCodec] = []
        for stream in audio {
            // An empty or absent codec normalizes to "", which matches nothing and so proceeds.
            guard let codec = stream.codec,
                  let match = UnplayableCodec.matching(codec) else { return .mayHaveAudio }
            unplayable.append(match)
        }
        return .noDecodableAudio(unplayable[0])
    }

    /// One diagnostic line per live tune, so a report can tell "checked, the audio is fine" apart
    /// from "the server named no audio at all". The raw codec strings are kept verbatim: their
    /// spelling is the finding whenever this check fails to fire.
    ///
    /// The index is worth printing even though a tuner channel reports `-1` for every stream
    /// (Jellyfin hardcodes it on the lineup-derived streams), because a probed source does not.
    static func logLine(for streams: [MediaStream]?) -> String {
        let audio = (streams ?? []).filter { $0.type == .audio }
        guard !audio.isEmpty else { return "[Live] audio streams: none reported" }
        let listed = audio
            .map { "\($0.index)=\($0.codec.flatMap { $0.isEmpty ? nil : $0 } ?? "?")" }
            .joined(separator: " ")
        return "[Live] audio streams: \(listed) verdict=\(verdictToken(verdict(for: streams)))"
    }

    private static func verdictToken(_ verdict: Verdict) -> String {
        switch verdict {
        case .noAudioReported: return "noAudioReported"
        case .mayHaveAudio: return "mayHaveAudio"
        case .noDecodableAudio(let codec): return "noDecodableAudio(\(codec.displayName))"
        }
    }

    /// Lowercase, everything that is not a letter or digit removed, so "AC-4", "AC4" and "ac4" are
    /// one value and `mpegh_3d_audio` matches `mpegh3daudio`.
    private static func normalize(_ codec: String) -> String {
        codec.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
