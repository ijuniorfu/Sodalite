import Foundation

// MARK: - PlaybackInfo Response

struct PlaybackInfoResponse: Codable, Sendable {
    let mediaSources: [PlaybackMediaSource]
    let playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}

struct PlaybackMediaSource: Codable, Sendable, Identifiable {
    let id: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let transcodingUrl: String?
    let mediaStreams: [MediaStream]?
    /// Set when PlaybackInfo opened a live tuner; echoed on stop + LiveStreams/Close to release it. Nil for VOD.
    let liveStreamId: String?
    /// Transcode reason(s) (e.g. `ContainerNotSupported`, `VideoCodecNotSupported`, `VideoBitrateNotSupported`); decisive signal for full video re-encode vs cheap remux, drives live copy-vs-encode tuning.
    let transcodeReasons: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingUrl = "TranscodingUrl"
        case mediaStreams = "MediaStreams"
        case liveStreamId = "LiveStreamId"
        case transcodeReasons = "TranscodeReasons"
    }
}

// MARK: - Media Segments

/// `/MediaSegments/{itemId}` intro/outro/preview markers; native on Jellyfin 10.10+, intro-skipper plugin on 10.9.
struct MediaSegmentsResponse: Codable, Sendable {
    let items: [MediaSegment]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct MediaSegment: Codable, Sendable, Identifiable {
    let id: String
    let itemId: String
    let type: SegmentType
    let startTicks: Int64
    let endTicks: Int64

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case itemId = "ItemId"
        case type = "Type"
        case startTicks = "StartTicks"
        case endTicks = "EndTicks"
    }

    /// Seconds, 10_000_000 ticks per second.
    var startSeconds: Double { Double(startTicks) / 10_000_000 }
    var endSeconds: Double { Double(endTicks) / 10_000_000 }
}

/// Paired result for one item's intro + outro markers, returned in a
/// single request to `/MediaSegments/{itemId}`. Either (or both) may
/// be nil if the server didn't detect that segment type.
struct EpisodeSegments: Sendable {
    let intro: MediaSegment?
    let outro: MediaSegment?
}

enum SegmentType: String, Codable, Sendable {
    case intro = "Intro"
    case outro = "Outro"
    case preview = "Preview"
    case recap = "Recap"
    case commercial = "Commercial"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SegmentType(rawValue: raw) ?? .unknown
    }
}

// MARK: - Session Reports

struct PlaybackStartReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String
    let playSessionId: String?
    let positionTicks: Int64
    let canSeek: Bool
    let playMethod: PlayMethod
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
    }
}

struct PlaybackProgressReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String
    let playSessionId: String?
    let positionTicks: Int64
    let isPaused: Bool
    let canSeek: Bool
    let playMethod: PlayMethod
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
    }
}

struct PlaybackStopReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String
    let playSessionId: String?
    let positionTicks: Int64
    /// Non-nil only for live streams; tells the server which tuner to
    /// release on stop.
    let liveStreamId: String?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case liveStreamId = "LiveStreamId"
    }
}

// MARK: - Play Method

enum PlayMethod: String, Encodable, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}
