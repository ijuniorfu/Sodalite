import Foundation

/// A Live TV channel. Server-side this is a `BaseItemDto` of type
/// `TvChannel`; we decode only the fields the guide needs.
struct JellyfinChannel: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let channelNumber: String?
    let imageTags: [String: String]?
    /// Present when the channel list is fetched with `addCurrentProgram=true`.
    let currentProgram: JellyfinProgram?
    /// Present when the channel list is fetched with `EnableUserData=true`.
    let userData: ChannelUserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case channelNumber = "ChannelNumber"
        case imageTags = "ImageTags"
        case currentProgram = "CurrentProgram"
        case userData = "UserData"
    }

    /// Primary image tag, used to build the channel-logo URL.
    var primaryImageTag: String? { imageTags?["Primary"] }

    /// Server-side favorite flag (nil when UserData wasn't requested).
    var isFavorite: Bool { userData?.isFavorite ?? false }
}

/// The slice of a channel's `UserData` the guide reads. Channels are
/// `BaseItemDto`, so favorites flow through the same UserData.IsFavorite the
/// regular media items use.
struct ChannelUserData: Codable, Sendable, Equatable {
    let isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
    }
}

/// A single EPG program. Server-side a `BaseItemDto` of type `Program`.
struct JellyfinProgram: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let channelId: String?
    let channelName: String?
    let name: String
    let overview: String?
    let startDate: Date?
    let endDate: Date?
    let genres: [String]?
    let imageTags: [String: String]?
    let isLive: Bool?
    let isNews: Bool?
    let isMovie: Bool?
    let isSeries: Bool?
    let isKids: Bool?
    let isSports: Bool?
    /// Set when a single-program record timer exists for this program.
    let timerId: String?
    /// Set when a series timer covers this program.
    let seriesTimerId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case channelId = "ChannelId"
        case channelName = "ChannelName"
        case name = "Name"
        case overview = "Overview"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case genres = "Genres"
        case imageTags = "ImageTags"
        case isLive = "IsLive"
        case isNews = "IsNews"
        case isMovie = "IsMovie"
        case isSeries = "IsSeries"
        case isKids = "IsKids"
        case isSports = "IsSports"
        case timerId = "TimerId"
        case seriesTimerId = "SeriesTimerId"
    }

    var primaryImageTag: String? { imageTags?["Primary"] }

    /// True for the placeholder the guide synthesizes for channels
    /// without program data ("live-<channelID>"). Such ids do not exist
    /// server-side; record affordances must not be offered.
    var isSynthesized: Bool { id.hasPrefix("live-") }

    /// True when `now` falls inside [startDate, endDate).
    func isAiring(at now: Date) -> Bool {
        guard let start = startDate, let end = endDate else { return false }
        return now >= start && now < end
    }
}

/// Global EPG bounds from `/LiveTv/GuideInfo`; sets the guide's time axis.
struct JellyfinGuideInfo: Codable, Sendable, Equatable {
    let startDate: Date?
    let endDate: Date?

    enum CodingKeys: String, CodingKey {
        case startDate = "StartDate"
        case endDate = "EndDate"
    }
}

/// `/LiveTv/Channels` and `/LiveTv/Programs` both return the standard
/// `{ Items, TotalRecordCount }` envelope.
struct LiveTvChannelsResponse: Codable, Sendable {
    let items: [JellyfinChannel]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct LiveTvProgramsResponse: Codable, Sendable {
    let items: [JellyfinProgram]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

/// A scheduled single-program recording (`/LiveTv/Timers`).
struct LiveTvTimer: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let programId: String?
    let channelId: String?
    let name: String?
    let channelName: String?
    let startDate: Date?
    let endDate: Date?
    /// Set when this timer was spawned by a series timer.
    let seriesTimerId: String?
    /// "New" | "InProgress" | "Completed" | "Cancelled" | "Error".
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case programId = "ProgramId"
        case channelId = "ChannelId"
        case name = "Name"
        case channelName = "ChannelName"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case seriesTimerId = "SeriesTimerId"
        case status = "Status"
    }
}

/// A series recording rule (`/LiveTv/SeriesTimers`).
struct LiveTvSeriesTimer: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String?
    let channelName: String?
    let overview: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case channelName = "ChannelName"
        case overview = "Overview"
    }
}

struct LiveTvTimersResponse: Codable, Sendable {
    let items: [LiveTvTimer]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct LiveTvSeriesTimersResponse: Codable, Sendable {
    let items: [LiveTvSeriesTimer]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

extension JSONDecoder {
    /// Jellyfin timestamps carry up to 7 fractional-second digits with a
    /// trailing `Z`. `.iso8601` rejects >3 digits, so parse leniently.
    static let jellyfinLiveTv: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            // Allocate the formatter per call: `DateFormatter` is a mutable
            // reference type and this closure can run concurrently across
            // overlapping Live TV requests. A captured shared formatter
            // would race on `dateFormat`.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS'Z'",
                        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                        "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
                formatter.dateFormat = fmt
                if let date = formatter.date(from: raw) { return date }
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unparseable date: \(raw)")
        }
        return decoder
    }()
}
