import Foundation

struct JellyfinItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let sortName: String?
    let originalTitle: String?
    let overview: String?
    let type: ItemType
    let seriesName: String?
    let seriesId: String?
    let seasonId: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let productionYear: Int?
    let communityRating: Double?
    /// Rotten Tomatoes critic score (0-100); nil unless a metadata provider (OMDb) delivers it.
    let criticRating: Double?
    let officialRating: String?  // e.g. "PG-13"
    let runTimeTicks: Int64?
    let premiereDate: String?
    let endDate: String?
    let status: String?
    let genres: [String]?
    let taglines: [String]?
    let imageTags: ImageTags?
    let backdropImageTags: [String]?
    let parentBackdropImageTags: [String]?
    // `var` so detail views patch the in-memory resume position from the playback-stop payload (issue #24), no re-fetch.
    var userData: UserItemData?
    let mediaStreams: [MediaStream]?
    let mediaSources: [MediaSource]?
    let people: [PersonInfo]?
    let studios: [StudioInfo]?
    let collectionType: String?
    let childCount: Int?
    /// Local trailer count (requires LocalTrailerCount in Fields); gates the detail Trailer button. nil if unrequested.
    let localTrailerCount: Int?
    let seriesPrimaryImageTag: String?
    let providerIds: [String: String]?
    let chapters: [ChapterInfo]?
    let albumArtist: String?
    let artists: [String]?
    let albumId: String?
    let albumPrimaryImageTag: String?

    /// Display line for a track: the per-track artists if present,
    /// otherwise the album artist. nil when neither is set.
    var trackArtistLine: String? {
        if let artists, !artists.isEmpty { return artists.joined(separator: ", ") }
        return albumArtist
    }

    /// TMDB id (correlates with Seerr). Key is case-sensitive ("Tmdb"); older scanners wrote "tmdb", so check both.
    var tmdbID: Int? {
        guard let ids = providerIds else { return nil }
        let raw = ids["Tmdb"] ?? ids["tmdb"] ?? ids["TMDB"]
        return raw.flatMap(Int.init)
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case sortName = "SortName"
        case originalTitle = "OriginalTitle"
        case overview = "Overview"
        case type = "Type"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case productionYear = "ProductionYear"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case officialRating = "OfficialRating"
        case runTimeTicks = "RunTimeTicks"
        case premiereDate = "PremiereDate"
        case endDate = "EndDate"
        case status = "Status"
        case genres = "Genres"
        case taglines = "Taglines"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case userData = "UserData"
        case mediaStreams = "MediaStreams"
        case mediaSources = "MediaSources"
        case people = "People"
        case studios = "Studios"
        case collectionType = "CollectionType"
        case childCount = "ChildCount"
        case localTrailerCount = "LocalTrailerCount"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case providerIds = "ProviderIds"
        case chapters = "Chapters"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case albumId = "AlbumId"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
    }

    init(item: JellyfinItem, userData: UserItemData?) {
        self.id = item.id
        self.name = item.name
        self.sortName = item.sortName
        self.originalTitle = item.originalTitle
        self.overview = item.overview
        self.type = item.type
        self.seriesName = item.seriesName
        self.seriesId = item.seriesId
        self.seasonId = item.seasonId
        self.parentIndexNumber = item.parentIndexNumber
        self.indexNumber = item.indexNumber
        self.productionYear = item.productionYear
        self.communityRating = item.communityRating
        self.criticRating = item.criticRating
        self.officialRating = item.officialRating
        self.runTimeTicks = item.runTimeTicks
        self.premiereDate = item.premiereDate
        self.endDate = item.endDate
        self.status = item.status
        self.genres = item.genres
        self.taglines = item.taglines
        self.imageTags = item.imageTags
        self.backdropImageTags = item.backdropImageTags
        self.parentBackdropImageTags = item.parentBackdropImageTags
        self.userData = userData
        self.mediaStreams = item.mediaStreams
        self.mediaSources = item.mediaSources
        self.people = item.people
        self.studios = item.studios
        self.collectionType = item.collectionType
        self.childCount = item.childCount
        self.localTrailerCount = item.localTrailerCount
        self.seriesPrimaryImageTag = item.seriesPrimaryImageTag
        self.providerIds = item.providerIds
        self.chapters = item.chapters
        self.albumArtist = item.albumArtist
        self.artists = item.artists
        self.albumId = item.albumId
        self.albumPrimaryImageTag = item.albumPrimaryImageTag
    }

    init(seriesStub id: String, name: String) {
        self.id = id
        self.name = name
        self.sortName = nil
        self.originalTitle = nil
        self.overview = nil
        self.type = .series
        self.seriesName = nil
        self.seriesId = nil
        self.seasonId = nil
        self.parentIndexNumber = nil
        self.indexNumber = nil
        self.productionYear = nil
        self.communityRating = nil
        self.criticRating = nil
        self.officialRating = nil
        self.runTimeTicks = nil
        self.premiereDate = nil
        self.endDate = nil
        self.status = nil
        self.genres = nil
        self.taglines = nil
        self.imageTags = nil
        self.backdropImageTags = nil
        self.parentBackdropImageTags = nil
        self.userData = nil
        self.mediaStreams = nil
        self.mediaSources = nil
        self.people = nil
        self.studios = nil
        self.collectionType = nil
        self.childCount = nil
        self.localTrailerCount = nil
        self.seriesPrimaryImageTag = nil
        self.providerIds = nil
        self.chapters = nil
        self.albumArtist = nil
        self.artists = nil
        self.albumId = nil
        self.albumPrimaryImageTag = nil
    }

    /// Live-channel item so PlayerViewModel works unchanged for live playback; display name prefers the current program's title.
    init(liveChannel channel: JellyfinChannel, program: JellyfinProgram?) {
        self.id = channel.id
        self.name = program?.name ?? channel.name
        self.sortName = nil
        self.originalTitle = nil
        self.overview = program?.overview
        self.type = .tvChannel
        self.seriesName = nil
        self.seriesId = nil
        self.seasonId = nil
        self.parentIndexNumber = nil
        self.indexNumber = nil
        self.productionYear = nil
        self.communityRating = nil
        self.criticRating = nil
        self.officialRating = nil
        self.runTimeTicks = nil
        self.premiereDate = nil
        self.endDate = nil
        self.status = nil
        self.genres = program?.genres
        self.taglines = nil
        self.imageTags = nil
        self.backdropImageTags = nil
        self.parentBackdropImageTags = nil
        self.userData = nil
        self.mediaStreams = nil
        self.mediaSources = nil
        self.people = nil
        self.studios = nil
        self.collectionType = nil
        self.childCount = nil
        self.localTrailerCount = nil
        self.seriesPrimaryImageTag = nil
        self.providerIds = nil
        self.chapters = nil
        self.albumArtist = nil
        self.artists = nil
        self.albumId = nil
        self.albumPrimaryImageTag = nil
    }

    /// Patch resume position in place after playback stops (issue #24): sets ticks + recomputes playedPercentage, no server round-trip. Creates userData if none.
    mutating func setResumePosition(_ ticks: Int64) {
        let pct: Double?
        if let total = runTimeTicks, total > 0 {
            pct = min(100, max(0, Double(ticks) / Double(total) * 100))
        } else {
            pct = userData?.playedPercentage
        }
        let base = userData ?? UserItemData(
            playbackPositionTicks: nil, playCount: nil, isFavorite: nil,
            played: nil, unplayedItemCount: nil, playedPercentage: nil,
            lastPlayedDate: nil
        )
        userData = base.with(playbackPositionTicks: ticks, playedPercentage: pct)
    }

    static func == (lhs: JellyfinItem, rhs: JellyfinItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum ItemType: String, Codable, Sendable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case musicAlbum = "MusicAlbum"
    case audio = "Audio"
    case boxSet = "BoxSet"
    case collectionFolder = "CollectionFolder"
    case folder = "Folder"
    case playlist = "Playlist"
    case tvChannel = "TvChannel"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ItemType(rawValue: rawValue) ?? .unknown
    }
}

/// Chapter marker (from MKV/MP4 container or a tagger). `imageTag` is set only when the server generated a chapter thumbnail.
struct ChapterInfo: Codable, Sendable, Equatable, Hashable {
    let startPositionTicks: Int64
    let name: String?
    let imageTag: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
    }

    /// Start in seconds (10⁷ ticks/sec).
    var startSeconds: Double {
        Double(startPositionTicks) / 10_000_000
    }
}

struct ImageTags: Codable, Sendable, Equatable {
    let primary: String?
    let backdrop: String?
    let thumb: String?
    let logo: String?
    let banner: String?

    enum CodingKeys: String, CodingKey {
        case primary = "Primary"
        case backdrop = "Backdrop"
        case thumb = "Thumb"
        case logo = "Logo"
        case banner = "Banner"
    }
}

struct UserItemData: Codable, Sendable, Equatable {
    let playbackPositionTicks: Int64?
    let playCount: Int?
    let isFavorite: Bool?
    let played: Bool?
    let unplayedItemCount: Int?
    let playedPercentage: Double?
    /// ISO-8601 last-play timestamp; kept raw (model convention) and unparsed (recency ordering is server-side via SortBy=DatePlayed).
    let lastPlayedDate: String?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case unplayedItemCount = "UnplayedItemCount"
        case playedPercentage = "PlayedPercentage"
        case lastPlayedDate = "LastPlayedDate"
    }

    /// Copy with resume position (and, if known, played percentage) replaced; in-memory patch after playback stops (issue #24).
    func with(playbackPositionTicks ticks: Int64, playedPercentage pct: Double?) -> UserItemData {
        UserItemData(
            playbackPositionTicks: ticks,
            playCount: playCount,
            isFavorite: isFavorite,
            played: played,
            unplayedItemCount: unplayedItemCount,
            playedPercentage: pct,
            lastPlayedDate: lastPlayedDate
        )
    }
}

struct MediaStream: Codable, Sendable, Equatable, Identifiable {
    let index: Int
    let type: MediaStreamType
    let codec: String?
    let language: String?
    let displayTitle: String?
    let title: String?
    let isDefault: Bool?
    let isForced: Bool?
    let isExternal: Bool?
    let height: Int?
    let width: Int?
    let channels: Int?
    let videoRange: String?
    let videoRangeType: String?
    let averageFrameRate: Double?
    let realFrameRate: Double?
    let profile: String?
    let bitRate: Int?
    let dvProfile: Int?

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case title = "Title"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case isExternal = "IsExternal"
        case height = "Height"
        case width = "Width"
        case channels = "Channels"
        case videoRange = "VideoRange"
        case videoRangeType = "VideoRangeType"
        case averageFrameRate = "AverageFrameRate"
        case realFrameRate = "RealFrameRate"
        case profile = "Profile"
        case bitRate = "BitRate"
        case dvProfile = "DvProfile"
    }
}

enum MediaStreamType: String, Codable, Sendable {
    case video = "Video"
    case audio = "Audio"
    case subtitle = "Subtitle"
    case embeddedImage = "EmbeddedImage"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MediaStreamType(rawValue: rawValue) ?? .unknown
    }
}

struct MediaSource: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let mediaStreams: [MediaStream]?

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
        case mediaStreams = "MediaStreams"
    }
}

struct PersonInfo: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let role: String?
    let type: String?
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

struct StudioInfo: Codable, Sendable, Equatable {
    let id: String?
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}
