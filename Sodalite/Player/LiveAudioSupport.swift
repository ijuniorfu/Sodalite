import Foundation

/// Whether a live source's audio can reach a speaker at all, decided from the codec strings the
/// server named rather than from opening the stream (Sodalite#100).
///
/// An ATSC 3.0 channel carries AC-4, and nothing on THIS DEVICE decodes it: the only AC-4 decoder
/// in the FFmpeg world is Librempeg's, which declares itself GPLv3 (`ac4_decoder_deps="gplv3"`) and
/// so cannot enter an LGPL build, and tvOS has no AC-4 format constant either, so the native path
/// cannot take it. `find_stream_info` therefore never resolves the stream and burns its whole 60 s
/// budget before failing open with the track missing, which the viewer sees as a tuning indicator
/// that never stops.
///
/// The server is the exception, and it is why this ends in a decision rather than a refusal:
/// jellyfin-ffmpeg carries that same GPLv3 decoder (jellyfin-ffmpeg#387, in every release since
/// v6.0.1-8 of 2024-07-25), and Jellyfin is GPL so it may. A server that answers with an audio
/// re-encode can hand us a soundtrack we play, and refusing on the codec alone cut off the one
/// route home. Only when no such offer stands is there nothing left to try.
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


    /// What to do with a source whose every named audio track is a format this device cannot decode.
    enum Decision: Equatable {
        /// Nothing to act on: the audio is playable here, or the server named none.
        case proceed
        /// Audible only through the server's re-encode. Every route that carries the ORIGINAL
        /// soundtrack (the raw tuner file, the provider's own playlist) ends in silence for this
        /// source, so the tune has to reach the TranscodingUrl and may not try them first.
        case serverReencodeRequired(UnplayableCodec)
        /// No route to sound anywhere. Say so instead of spending the probe's budget on it.
        case refuse(UnplayableCodec)

        /// Whether the routes that carry the original soundtrack have to be given up. Only the one
        /// case: a channel we can decode keeps the tuner file the ranking prefers (#70), and a
        /// refusal never gets as far as choosing a route.
        var requiresServerReencode: Bool {
            if case .serverReencodeRequired = self { return true }
            return false
        }

        var logToken: String {
            switch self {
            case .proceed: return "proceed"
            case .serverReencodeRequired: return "serverReencode"
            case .refuse: return "refuse"
            }
        }
    }

    /// - Parameter serverOffersAudioReencode: whether Jellyfin answered with a TranscodingUrl that
    ///   rebuilds the AUDIO (`liveServerOffersAudioReencode`). A picture-only re-encode does not
    ///   count: it copies the soundtrack through untouched.
    static func decision(for streams: [MediaStream]?, serverOffersAudioReencode: Bool) -> Decision {
        guard case .noDecodableAudio(let codec) = verdict(for: streams) else { return .proceed }
        return serverOffersAudioReencode ? .serverReencodeRequired(codec) : .refuse(codec)
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
    static func logLine(for streams: [MediaStream]?, serverOffersAudioReencode: Bool) -> String {
        let audio = (streams ?? []).filter { $0.type == .audio }
        guard !audio.isEmpty else { return "[Live] audio streams: none reported" }
        let listed = audio
            .map { "\($0.index)=\($0.codec.flatMap { $0.isEmpty ? nil : $0 } ?? "?")" }
            .joined(separator: " ")
        let verdict = verdict(for: streams)
        var line = "[Live] audio streams: \(listed) verdict=\(verdictToken(verdict))"
        // Only where the codec check actually bit: on every other channel the decision is proceed by
        // construction, and a token saying so on every live tune is noise in a log a viewer reads.
        if case .noDecodableAudio = verdict {
            let decision = decision(for: streams, serverOffersAudioReencode: serverOffersAudioReencode)
            line += " decision=\(decision.logToken)"
        }
        return line
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
