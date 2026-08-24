import Foundation

/// The three pills a card can show: resolution, dynamic range, spatial audio (Sodalite#79).
///
/// Resolution rides on every card query (`Width` costs two ints out of the BaseItem row), the other
/// two only exist once `MediaStreams` have been fetched, so the resolver answers partially rather
/// than not at all: a poster paints "4K" immediately and grows "DV" when enrichment lands.
struct MediaBadges: Equatable, Sendable {

    /// Raw values are the pill text. Brand shorthand and line counts, not localised: "4K" is "4K"
    /// in every one of the 26 catalogs.
    enum Resolution: String, Sendable {
        case uhd = "4K"
        case fullHD = "1080p"
        case hd = "720p"
        case sd = "SD"
    }

    enum DynamicRange: String, Sendable {
        case dolbyVision = "DV"
        case hdr10Plus = "HDR10+"
        case hdr10 = "HDR10"
        case hlg = "HLG"
    }

    enum Audio: String, Sendable {
        case atmos = "ATMOS"
        case dtsX = "DTS:X"
    }

    var resolution: Resolution?
    var dynamicRange: DynamicRange?
    var audio: Audio?

    var isEmpty: Bool { resolution == nil && dynamicRange == nil && audio == nil }

    /// Top to bottom in the poster corner: what it is, how it looks, how it sounds. Absent facts
    /// leave no gap, an empty slot would read as something still loading.
    var pills: [String] {
        [resolution?.rawValue, dynamicRange?.rawValue, audio?.rawValue].compactMap { $0 }
    }
}

enum MediaBadgeResolver {

    /// `width` is the item-level `Width`; `streams` is nil until the badge store has enriched the id.
    static func badges(width: Int?, streams: [MediaStream]?) -> MediaBadges {
        let video = streams?.first { $0.type == .video }
        return MediaBadges(
            resolution: resolution(width: video?.width ?? width),
            dynamicRange: dynamicRange(video),
            audio: audio(streams)
        )
    }

    /// Width classifies, never height: a 3840x1600 scope master is a 4K master, and Jellyfin's own
    /// `Is4K` filter draws the line at the same place.
    private static func resolution(width: Int?) -> MediaBadges.Resolution? {
        guard let width, width > 0 else { return nil }
        switch width {
        case 3800...:  return .uhd
        case 1900...:  return .fullHD
        case 1260...:  return .hd
        default:       return .sd
        }
    }

    private static func dynamicRange(_ video: MediaStream?) -> MediaBadges.DynamicRange? {
        guard let video else { return nil }
        if video.dvProfile != nil { return .dolbyVision }
        switch video.videoRangeType?.uppercased() {
        case "HDR10PLUS":                                       return .hdr10Plus
        case "HDR10":                                           return .hdr10
        case "HLG":                                             return .hlg
        case "DOVI", "DOVIWITHHDR10", "DOVIWITHHLG", "DOVIWITHSDR":
            return .dolbyVision
        default:                                                return nil
        }
    }

    /// Spatial formats only. A channel count on every poster is noise, and the server derives its
    /// own `AudioSpatialFormat` from exactly this string, so reading `profile` keeps the pill
    /// working on servers too old to send that field.
    private static func audio(_ streams: [MediaStream]?) -> MediaBadges.Audio? {
        guard let streams else { return nil }
        for stream in streams where stream.type == .audio {
            guard let profile = stream.profile else { continue }
            if profile.localizedCaseInsensitiveContains("Dolby Atmos") { return .atmos }
            if profile.localizedCaseInsensitiveContains("DTS:X") { return .dtsX }
        }
        return nil
    }
}
