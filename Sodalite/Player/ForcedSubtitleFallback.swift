import Foundation
import AetherEngine

/// Disc-parity forced subtitles: with subtitles OFF, forced captions (signs, foreign-dialogue
/// overlays) still show, like a disc player or TV would. Resolution order:
///
/// 1. `.forcedTrack`: a dedicated forced track (flag or "forced" title) in the audio language,
///    rendered whole. An untagged single forced track passes when nothing language-matched exists.
/// 2. `.cueFilter`: no dedicated track, but a full/SDH embedded BITMAP track in the audio language;
///    its cues are filtered to the per-cue forced flag (AetherEngine 5.9.5, AE#146). Text codecs
///    carry forcedness only per track, so they never qualify here.
///
/// The selection is engine-silent: `activeSubtitleIndex` stays nil, the picker keeps showing
/// "Off", and nothing changes in session reporting. `PlayerViewModel.applyForcedSubtitleFallback`
/// owns the wiring; this type owns the pure decisions so they stay unit-testable.
enum ForcedSubtitleFallback {
    enum Mode: Equatable {
        case none
        /// Dedicated forced track: select it silently and render every cue.
        case forcedTrack(streamIndex: Int)
        /// Full bitmap track: select it silently and render only cues with `isForced`.
        case cueFilter(streamIndex: Int)
    }

    static func resolve(streams: [MediaStream], audioLanguage: String?) -> Mode {
        let subs = streams.filter { $0.type == .subtitle }

        let forced = subs.filter { isForcedTrack($0) }
        if let match = forced.first(where: { PlayerViewModel.languagesMatch($0.language, audioLanguage) }) {
            return .forcedTrack(streamIndex: match.index)
        }
        // A single untagged forced track is near-universally authored for the main audio; a single
        // track in a DIFFERENT language is not (wrong-language forced subs are worse than none).
        if forced.count == 1, let only = forced.first,
           isLanguageUnknown(only.language) || audioLanguage == nil {
            return .forcedTrack(streamIndex: only.index)
        }

        let candidates = subs.filter { isCueFilterCandidate($0) }
        if let match = candidates
            .filter({ PlayerViewModel.languagesMatch($0.language, audioLanguage) })
            .min(by: { cueFilterRank($0) < cueFilterRank($1) }) {
            return .cueFilter(streamIndex: match.index)
        }
        if candidates.count == 1, let only = candidates.first,
           isLanguageUnknown(only.language) || audioLanguage == nil {
            return .cueFilter(streamIndex: only.index)
        }
        return .none
    }

    /// `.cueFilter` keeps only forced cues; the other modes pass the array through untouched
    /// (a dedicated forced track is forced-only by authoring).
    static func filteredCues(_ cues: [SubtitleCue], mode: Mode) -> [SubtitleCue] {
        guard case .cueFilter = mode else { return cues }
        return cues.filter(\.isForced)
    }

    private static func isForcedTrack(_ stream: MediaStream) -> Bool {
        stream.isForced == true || (stream.title?.lowercased().contains("forced") ?? false)
    }

    /// Embedded full/SDH bitmap tracks only: per-cue forced flags exist only on bitmap codecs, the
    /// overlay drainer serves only embedded streams without a second connection, and special-purpose
    /// tracks (signs/songs/commentary) are curated subsets that do not carry the disc's forced set.
    private static func isCueFilterCandidate(_ stream: MediaStream) -> Bool {
        guard stream.isExternal != true, !isForcedTrack(stream) else { return false }
        let codec = stream.codec?.lowercased() ?? ""
        let isBitmap = ["pgs", "hdmv", "dvb_sub", "dvbsub", "dvd_sub", "dvdsub", "vobsub", "xsub"]
            .contains(where: { codec.contains($0) })
        guard isBitmap else { return false }
        let title = stream.title?.lowercased() ?? ""
        return !["signs", "songs", "music", "musik", "commentary"].contains(where: { title.contains($0) })
    }

    /// Full beats SDH: the plain track mirrors the disc's authored forced set most closely.
    private static func cueFilterRank(_ stream: MediaStream) -> Int {
        let title = stream.title?.lowercased() ?? ""
        return ["sdh", "cc", "hearing"].contains(where: { title.contains($0) }) ? 1 : 0
    }

    private static func isLanguageUnknown(_ language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }
        return language.lowercased() == "und"
    }
}
