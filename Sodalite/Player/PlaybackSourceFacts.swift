import Foundation

/// What the stats panel needs to describe the media, resolved from the two places it can come from.
///
/// The launch `JellyfinItem` is not a reliable description of what is playing. Episode rows arrive from a
/// list query whose fields carry neither `MediaSources` nor `MediaStreams`; a movie arrives from a detail
/// fetch whose fields carry both. The session's own PlaybackInfo `MediaSource` has them on every path
/// except the remembered-URL live shortcut, and it names the version actually playing rather than the
/// first one listed, so it is asked first.
///
/// Fallback is field by field rather than all or nothing: a live source names a tuner path and no size,
/// and blanking a row the item could have answered would trade one gap for another.
struct PlaybackSourceFacts: Equatable {
    var container: String?
    var sizeBytes: Int64?
    /// The server-side path. This is the one thing the engine structurally cannot know: it is handed
    /// `/Videos/{id}/stream.mkv?api_key=...`, and only Jellyfin holds `/media/Shows/…/S01E01.mkv`.
    var path: String?
    var bitrate: Int?
    var streams: [MediaStream]

    /// Whether anything at all resolved, so the file section can stay out of the panel rather than render
    /// a heading over three dashes.
    var hasAny: Bool {
        container != nil || sizeBytes != nil || path != nil || bitrate != nil || !streams.isEmpty
    }

    var fileName: String? {
        guard let path, let last = path.split(separator: "/").last else { return nil }
        return String(last)
    }

    func stream(ofType type: MediaStreamType) -> MediaStream? {
        streams.first { $0.type == type }
    }

    func stream(ofType type: MediaStreamType, index: Int?) -> MediaStream? {
        guard let index else { return nil }
        return streams.first { $0.type == type && $0.index == index }
    }

    static func resolve(
        session: PlaybackMediaSource?,
        item: JellyfinItem,
        selectedMediaSourceID: String?
    ) -> PlaybackSourceFacts {
        let itemSource = item.effectiveMediaSource(id: selectedMediaSourceID)
        let itemStreams = item.effectiveMediaStreams(id: selectedMediaSourceID) ?? []
        return PlaybackSourceFacts(
            container: session?.container ?? itemSource?.container,
            sizeBytes: session?.size ?? itemSource?.size,
            path: session?.path ?? itemSource?.path,
            bitrate: session?.bitrate ?? itemSource?.bitrate,
            streams: session?.mediaStreams ?? itemStreams)
    }
}
