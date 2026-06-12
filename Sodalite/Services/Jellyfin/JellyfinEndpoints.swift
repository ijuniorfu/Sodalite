import Foundation

enum JellyfinEndpoint: APIEndpoint {
    // Server
    case publicInfo
    case publicUsers

    // Auth
    case authenticateByName(username: String, password: String)
    case currentUser

    // Quick Connect
    case quickConnectInitiate
    case quickConnectCheck(secret: String)
    case quickConnectAuthenticate(secret: String)

    // Libraries
    case userViews(userID: String)

    // Items
    case items(userID: String, query: ItemQuery)
    case itemDetail(userID: String, itemID: String)
    case resumeItems(userID: String, mediaType: String, limit: Int)
    case nextUp(userID: String, seriesID: String?, limit: Int)
    case latestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int)
    case seasons(seriesID: String, userID: String)
    case episodes(seriesID: String, seasonID: String, userID: String)
    case similarItems(itemID: String, userID: String, limit: Int)
    /// DELETE /Items/{itemID} — server-side delete. Jellyfin handles
    /// the cascade (series -> seasons -> episodes) on its own; we call
    /// this once per item.
    case deleteItem(itemID: String)

    // Genres & Studios
    case genres(userID: String)
    case studios(userID: String)

    // Playback. The PlaybackInfo body is the DeviceProfile dictionary
    // (built as [String: Any] by DirectPlayProfile), bridged through
    // JSONValue so the HTTPClient's Encodable body path can carry it.
    case playbackInfo(itemID: String, userID: String, payload: JSONValue)
    case livePlaybackInfo(itemID: String, userID: String, maxStreamingBitrate: Int, payload: JSONValue)
    case sessionPlaying(report: PlaybackStartReport)
    case sessionProgress(report: PlaybackProgressReport)
    case sessionStopped(report: PlaybackStopReport)

    // Favorites
    case markFavorite(userID: String, itemID: String)
    case unmarkFavorite(userID: String, itemID: String)

    // Played
    case markPlayed(userID: String, itemID: String)
    case unmarkPlayed(userID: String, itemID: String)

    // Search
    case searchHints(userID: String, query: String, limit: Int)

    // Media Segments (Intro / Outro markers, Jellyfin 10.10+ native,
    // or intro-skipper plugin on older servers)
    case mediaSegments(itemID: String)

    // Live TV
    case liveTvChannels(userID: String, startIndex: Int, limit: Int)
    case liveTvPrograms(channelIDs: [String], userID: String, minEndDate: Date, maxStartDate: Date)
    case liveTvGuideInfo
    case closeLiveStream(liveStreamID: String)
    /// DELETE /Videos/ActiveEncodings: kill the server-side transcode job
    /// for this (device, play session) and DELETE its output files. The
    /// canonical cleanup call jellyfin-web fires on every stop. Without
    /// it, a live transcode whose PlaybackStopped report is lost (app
    /// kill, network drop, crash) keeps ffmpeg writing an endlessly
    /// growing stream.ts until the server disk fills.
    case stopActiveEncodings(deviceID: String, playSessionID: String)
    case liveTvRecordings(userID: String, isInProgress: Bool?)
    case liveTvTimers
    case liveTvSeriesTimers
    case liveTvTimerDefaults(programID: String)
    case createLiveTvTimer(payload: JSONValue)
    case deleteLiveTvTimer(timerID: String)
    case createLiveTvSeriesTimer(payload: JSONValue)
    case deleteLiveTvSeriesTimer(timerID: String)

    var path: String {
        switch self {
        case .publicInfo:
            "/System/Info/Public"
        case .publicUsers:
            "/Users/Public"
        case .authenticateByName:
            "/Users/AuthenticateByName"
        case .currentUser:
            "/Users/Me"
        case .quickConnectInitiate:
            "/QuickConnect/Initiate"
        case .quickConnectCheck:
            "/QuickConnect/Connect"
        case .quickConnectAuthenticate:
            "/Users/AuthenticateWithQuickConnect"
        case .userViews(let userID):
            "/Users/\(userID)/Views"
        case .items(let userID, _):
            "/Users/\(userID)/Items"
        case .itemDetail(let userID, let itemID):
            "/Users/\(userID)/Items/\(itemID)"
        case .resumeItems(let userID, _, _):
            "/Users/\(userID)/Items/Resume"
        case .nextUp:
            "/Shows/NextUp"
        case .latestMedia(let userID, _, _, _):
            "/Users/\(userID)/Items/Latest"
        case .seasons(let seriesID, _):
            "/Shows/\(seriesID)/Seasons"
        case .episodes(let seriesID, _, _):
            "/Shows/\(seriesID)/Episodes"
        case .similarItems(let itemID, _, _):
            "/Items/\(itemID)/Similar"
        case .deleteItem(let itemID):
            "/Items/\(itemID)"
        case .genres:
            "/Genres"
        case .studios:
            "/Studios"
        case .playbackInfo(let itemID, _, _), .livePlaybackInfo(let itemID, _, _, _):
            "/Items/\(itemID)/PlaybackInfo"
        case .sessionPlaying:
            "/Sessions/Playing"
        case .sessionProgress:
            "/Sessions/Playing/Progress"
        case .sessionStopped:
            "/Sessions/Playing/Stopped"
        case .markFavorite(let userID, let itemID):
            "/Users/\(userID)/FavoriteItems/\(itemID)"
        case .unmarkFavorite(let userID, let itemID):
            "/Users/\(userID)/FavoriteItems/\(itemID)"
        case .markPlayed(let userID, let itemID):
            "/Users/\(userID)/PlayedItems/\(itemID)"
        case .unmarkPlayed(let userID, let itemID):
            "/Users/\(userID)/PlayedItems/\(itemID)"
        case .searchHints:
            "/Search/Hints"
        case .mediaSegments(let itemID):
            "/MediaSegments/\(itemID)"
        case .liveTvChannels:
            "/LiveTv/Channels"
        case .liveTvPrograms:
            "/LiveTv/Programs"
        case .liveTvGuideInfo:
            "/LiveTv/GuideInfo"
        case .closeLiveStream:
            "/LiveTv/LiveStreams/Close"
        case .stopActiveEncodings:
            "/Videos/ActiveEncodings"
        case .liveTvRecordings:
            "/LiveTv/Recordings"
        case .liveTvTimers, .createLiveTvTimer:
            "/LiveTv/Timers"
        case .liveTvSeriesTimers, .createLiveTvSeriesTimer:
            "/LiveTv/SeriesTimers"
        case .liveTvTimerDefaults:
            "/LiveTv/Timers/Defaults"
        case .deleteLiveTvTimer(let timerID):
            "/LiveTv/Timers/\(timerID)"
        case .deleteLiveTvSeriesTimer(let timerID):
            "/LiveTv/SeriesTimers/\(timerID)"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .authenticateByName, .quickConnectInitiate, .quickConnectAuthenticate, .markFavorite,
             .markPlayed,
             .playbackInfo, .livePlaybackInfo,
             .sessionPlaying, .sessionProgress, .sessionStopped,
             .closeLiveStream,
             .createLiveTvTimer, .createLiveTvSeriesTimer:
            .post
        case .unmarkFavorite, .unmarkPlayed, .deleteItem, .stopActiveEncodings,
             .deleteLiveTvTimer, .deleteLiveTvSeriesTimer:
            .delete
        default:
            .get
        }
    }

    /// Session-reporting writes run detached / fire-and-forget after
    /// the user has dismissed the player (stopPlayback) or as a
    /// background timer (progress). They no longer block any UI, so
    /// the 30 s default is overly aggressive — if a slow CDN origin
    /// stalls for 35 s, the position write is dropped and Jellyfin
    /// keeps the stale resume point. 90 s gives the server enough
    /// grace to accept the write even on hiccupping origins, per
    /// DrHurt's caution on Sodalite#12 ("don't timeout on it too
    /// soon"). Everything else keeps the 30 s default.
    var timeoutInterval: TimeInterval? {
        switch self {
        case .sessionPlaying, .sessionProgress, .sessionStopped:
            return 90
        case .playbackInfo, .livePlaybackInfo:
            // PlaybackInfo ran on URLSession.shared (60 s default)
            // before it moved onto the HTTPClient stack; keep that
            // ceiling. The live variant especially needs it:
            // AutoOpenLiveStream opens + probes the tuner server-side,
            // and slow IPTV tuners regularly exceed the 30 s default.
            return 60
        default:
            return nil
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .quickConnectCheck(let secret):
            return [URLQueryItem(name: "secret", value: secret)]

        case .playbackInfo(_, let userID, _):
            return [URLQueryItem(name: "UserId", value: userID)]

        case .livePlaybackInfo(_, let userID, let maxStreamingBitrate, _):
            // AutoOpenLiveStream opens + probes the tuner so the source
            // codecs are known (so Jellyfin can DirectStream/copy instead
            // of always re-encoding) and a real LiveStreamId comes back.
            // IsPlayback marks a real play. MaxStreamingBitrate caps any
            // transcode the server falls to.
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "AutoOpenLiveStream", value: "true"),
                URLQueryItem(name: "IsPlayback", value: "true"),
                URLQueryItem(name: "StartTimeTicks", value: "0"),
                URLQueryItem(name: "MaxStreamingBitrate", value: String(maxStreamingBitrate)),
            ]

        case .items(_, let query):
            return query.toQueryItems()

        case .itemDetail:
            // /Users/{id}/Items/{id} otherwise omits the extended
            // `Fields` (including RemoteTrailers, which the Trailer
            // button needs to resolve YouTube URLs for a detail
            // item). defaultFields is our standard "give me enough
            // to render a rich detail view" set.
            return [URLQueryItem(name: "Fields", value: Self.defaultFields)]

        case .resumeItems(_, let mediaType, let limit):
            return [
                URLQueryItem(name: "MediaTypes", value: mediaType),
                URLQueryItem(name: "Limit", value: String(limit)),
                // Continue Watching feeds a Home carousel (and the
                // resume deep-link, which only reads the item id), so
                // the slim home field set is all it needs, see homeRowFields.
                URLQueryItem(name: "Fields", value: Self.homeRowFields),
            ]

        case .nextUp(let userID, let seriesID, let limit):
            var items = [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "Limit", value: String(limit)),
                // Next Up feeds a Home carousel and the series-detail play
                // button (which renders only name / index / runtime / resume,
                // all base or UserData fields), so the slim set suffices.
                URLQueryItem(name: "Fields", value: Self.homeRowFields),
                // Exclude in-progress (resumable) episodes from Next Up so a
                // partially-watched episode shows only in Continue Watching,
                // not in both rows. Jellyfin returns the same episode from
                // /Shows/NextUp and /Users/{id}/Items/Resume otherwise, and
                // the two Home rows are fetched independently with no
                // client-side dedup. Ignored by Jellyfin servers predating
                // the parameter, which simply leaves the prior behaviour.
                URLQueryItem(name: "EnableResumable", value: "false"),
            ]
            if let seriesID {
                items.append(URLQueryItem(name: "SeriesId", value: seriesID))
            }
            return items

        case .latestMedia(_, let parentID, let includeItemTypes, let limit):
            var items = [
                URLQueryItem(name: "Limit", value: String(limit)),
                // Latest Movies / Shows / per-library Latest are all Home
                // carousels; slim field set, the card renders image + title
                // + year only (see homeRowFields).
                URLQueryItem(name: "Fields", value: Self.homeRowFields),
            ]
            if let parentID {
                items.append(URLQueryItem(name: "ParentId", value: parentID))
            }
            if let includeItemTypes {
                // Filter /Items/Latest to one specific item type,
                // without it, dropping ParentId means the row
                // aggregates movies + series + music in a random
                // jumble instead of feeding a typed "Latest Movies"
                // or "Latest Shows" row.
                items.append(URLQueryItem(
                    name: "IncludeItemTypes",
                    value: includeItemTypes.map(\.rawValue).joined(separator: ",")
                ))
            }
            return items

        case .seasons(_, let userID):
            return [
                URLQueryItem(name: "UserId", value: userID),
                // Slim field set, NOT defaultFields. The season bar only
                // renders the name (a base field); index, childCount and
                // watched state (UserData) ride along with UserId. Dropping
                // the heavy per-season arrays here matters because getSeasons
                // gates the whole season + episode section from appearing,
                // it was the slowest of the detail round-trips on slow CDNs.
                URLQueryItem(name: "Fields", value: Self.seasonListFields),
            ]

        case .episodes(_, let seasonID, let userID):
            return [
                URLQueryItem(name: "SeasonId", value: seasonID),
                URLQueryItem(name: "UserId", value: userID),
                // Slim field set, NOT defaultFields. The episode row only
                // needs the overview and the primary image tag, name /
                // index / runtime are base fields and UserData (watched
                // badge, resume progress) comes back automatically with
                // UserId. Dropping MediaStreams / MediaSources / People /
                // Chapters / Studios here is the big win for slow servers:
                // those per-episode arrays bloat the list response and were
                // the reason the row took seconds to land. The episode
                // detail (TechInfoBox) pulls the full field set lazily when
                // an episode is actually opened.
                URLQueryItem(name: "Fields", value: Self.episodeListFields),
            ]

        case .similarItems(_, let userID, let limit):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "Limit", value: String(limit)),
            ]

        case .genres(let userID):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]

        case .studios(let userID):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]

        case .searchHints(let userID, let query, let limit):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "SearchTerm", value: query),
                URLQueryItem(name: "Limit", value: String(limit)),
            ]

        case .mediaSegments:
            // Request both Intro (skip-intro button) and Outro (drives the
            // early next-episode overlay). Repeated same-name items bind to
            // ASP.NET's list parameter: ?includeSegmentTypes=Intro&includeSegmentTypes=Outro.
            return [
                URLQueryItem(name: "includeSegmentTypes", value: "Intro"),
                URLQueryItem(name: "includeSegmentTypes", value: "Outro"),
            ]

        case .liveTvChannels(let userID, let startIndex, let limit):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "AddCurrentProgram", value: "true"),
                // UserData carries IsFavorite; favorite sorting floats
                // favorited channels to the top server-side, which keeps the
                // guide's StartIndex pagination and incremental diffing intact
                // (a client-side re-sort would break both).
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "EnableFavoriteSorting", value: "true"),
            ]

        case .liveTvPrograms(let channelIDs, let userID, let minEnd, let maxStart):
            // Local formatter: ISO8601DateFormatter is not Sendable, so it
            // cannot be a shared static under Swift 6 strict concurrency.
            // Guide program-window requests are low-frequency, so the
            // per-call allocation is negligible.
            let iso = ISO8601DateFormatter()
            return [
                URLQueryItem(name: "ChannelIds", value: channelIDs.joined(separator: ",")),
                URLQueryItem(name: "UserId", value: userID),
                // Overlap semantics, NOT containment: a program belongs in
                // the guide window when it ends after the window starts
                // (MinEndDate) and starts before the window ends
                // (MaxStartDate). The earlier MinStartDate filter dropped
                // every program that began before the axis start, i.e.
                // exactly the ones airing RIGHT NOW, so the first column
                // of the EPG was empty and those channels unplayable from
                // the grid.
                URLQueryItem(name: "MinEndDate", value: iso.string(from: minEnd)),
                URLQueryItem(name: "MaxStartDate", value: iso.string(from: maxStart)),
                URLQueryItem(name: "SortBy", value: "StartDate"),
                URLQueryItem(name: "EnableImages", value: "true"),
            ]

        case .closeLiveStream(let liveStreamID):
            return [URLQueryItem(name: "LiveStreamId", value: liveStreamID)]

        case .stopActiveEncodings(let deviceID, let playSessionID):
            return [
                URLQueryItem(name: "deviceId", value: deviceID),
                URLQueryItem(name: "playSessionId", value: playSessionID),
            ]

        case .liveTvRecordings(let userID, let isInProgress):
            var items = [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "Fields", value: "Overview"),
                // userData.playbackPositionTicks drives resume playback,
                // matching the same flag on liveTvChannels (~line 347).
                URLQueryItem(name: "EnableUserData", value: "true"),
            ]
            // Active-recording detection: modern Jellyfin does not
            // populate BaseItemDto.Status on recording items; the
            // IsInProgress query filter is how jellyfin-web finds the
            // active ones (verified against the live server: the filter
            // is accepted and returns the standard envelope).
            if let isInProgress {
                items.append(URLQueryItem(name: "IsInProgress", value: isInProgress ? "true" : "false"))
            }
            return items

        case .liveTvTimerDefaults(let programID):
            return [URLQueryItem(name: "programId", value: programID)]

        default:
            return nil
        }
    }

    var body: (any Encodable & Sendable)? {
        switch self {
        case .authenticateByName(let username, let password):
            AuthenticateBody(username: username, pw: password)
        case .quickConnectAuthenticate(let secret):
            QuickConnectAuthBody(secret: secret)
        case .playbackInfo(_, _, let payload), .livePlaybackInfo(_, _, _, let payload):
            payload
        case .sessionPlaying(let report):
            report
        case .sessionProgress(let report):
            report
        case .sessionStopped(let report):
            report
        case .createLiveTvTimer(let payload), .createLiveTvSeriesTimer(let payload):
            payload
        default:
            nil
        }
    }

    var requiresAuth: Bool {
        switch self {
        case .publicInfo, .publicUsers, .authenticateByName, .quickConnectInitiate, .quickConnectCheck:
            false
        default:
            true
        }
    }

    static let defaultFields = "Overview,Genres,People,Studios,MediaStreams,MediaSources,CommunityRating,OfficialRating,ImageTags,BackdropImageTags,ParentBackdropImageTags,SeriesPrimaryImageTag,ProviderIds,Chapters"

    /// Minimal field set for the season bar. ItemCounts keeps childCount
    /// (used to size the loading skeleton's card count) without dragging in
    /// the heavy metadata arrays defaultFields would. Name / index / watched
    /// state come back as base fields / with the UserId query.
    static let seasonListFields = "ItemCounts"

    /// Minimal field set for the per-season episode list. Only what the
    /// episode cards render: synopsis + thumbnail. Everything else the card
    /// shows (name, index number, runtime, watched/resume state) is either a
    /// base field or rides along with the UserId query, so it costs nothing
    /// extra. Heavy per-episode arrays (MediaStreams, MediaSources, People,
    /// Chapters) are deliberately omitted, the episode detail fetch pulls
    /// those on demand when an episode is opened.
    static let episodeListFields = "Overview,ImageTags"

    /// Minimal field set for the Home carousels (Continue Watching, Next Up,
    /// Latest, All Movies/Series, Favorites, Top Rated, Recently Added,
    /// Collections, per-library Latest). The home cards only render a poster
    /// or backdrop, the title, a year/series subtitle and the watched/resume
    /// badge, so all we need are the image tags. Name / index / runtime /
    /// productionYear / seriesName are base fields and UserData (watched +
    /// resume %) rides along with the UserId query. Everything the old
    /// defaultFields pulled per item (Overview, Genres, People, Studios,
    /// MediaStreams, MediaSources, Chapters, ProviderIds, ratings) is dead
    /// weight on a row of 16-30 items, exactly the kind of payload bloat that
    /// was slowing the episode list before it was slimmed (Sodalite#12,
    /// DrHurt's Fields= audit). Tapping a card opens Detail, which re-fetches
    /// the full field set, so nothing downstream loses data.
    ///
    /// `nonisolated` because the Home background precompute reads it from
    /// inside detached task-group closures (provider / genre resolves) that
    /// don't inherit the type's MainActor isolation. It's an immutable
    /// String constant, so sharing it across actors is safe.
    nonisolated static let homeRowFields = "ImageTags,BackdropImageTags,ParentBackdropImageTags,SeriesPrimaryImageTag"

    /// Slim Fields= set for music browse rows (albums grid, track
    /// lists). Image tags + the album/artist linkage the cards render;
    /// IndexNumber / ParentIndexNumber / RunTimeTicks / ProductionYear
    /// come back without an explicit Fields request.
    nonisolated static let musicListFields = "ImageTags,Artists,AlbumArtist,AlbumId,AlbumPrimaryImageTag"
}

struct ItemQuery: Sendable {
    var parentID: String?
    /// Exact item-id lookup (`Ids=` on /Items). Used to batch-resolve
    /// parent series for episode entries that /Items/Latest returns
    /// ungrouped (series with exactly one fresh episode).
    var ids: [String]?
    var includeItemTypes: [ItemType]?
    var sortBy: String?
    var sortOrder: String?
    var limit: Int?
    var startIndex: Int?
    var searchTerm: String?
    var genres: [String]?
    var studioNames: [String]?
    var isFavorite: Bool?
    /// Jellyfin `Filters` values (`IsPlayed`, `IsUnplayed`,
    /// `IsResumable`, ...). Drives the watch-status filter on the
    /// library grids (Sodalite#17).
    var filters: [String]?
    /// Single-value provider-id match like "tmdb.123", used by the
    /// home-page smart provider filter to look up library items by
    /// TMDB id one at a time. Jellyfin's `AnyProviderIdEquals`
    /// accepts only a single value, so multi-id lookups have to be
    /// fanned out as parallel queries with this field.
    var anyProviderIdEquals: String?
    var fields: String?

    func toQueryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        if let parentID { items.append(URLQueryItem(name: "ParentId", value: parentID)) }
        if let ids {
            items.append(URLQueryItem(name: "Ids", value: ids.joined(separator: ",")))
        }
        if let types = includeItemTypes {
            items.append(URLQueryItem(name: "IncludeItemTypes", value: types.map(\.rawValue).joined(separator: ",")))
        }
        if let sortBy { items.append(URLQueryItem(name: "SortBy", value: sortBy)) }
        if let sortOrder { items.append(URLQueryItem(name: "SortOrder", value: sortOrder)) }
        if let limit { items.append(URLQueryItem(name: "Limit", value: String(limit))) }
        if let startIndex { items.append(URLQueryItem(name: "StartIndex", value: String(startIndex))) }
        if let searchTerm { items.append(URLQueryItem(name: "SearchTerm", value: searchTerm)) }
        if let genres {
            items.append(URLQueryItem(name: "Genres", value: genres.joined(separator: "|")))
        }
        if let studioNames {
            items.append(URLQueryItem(name: "Studios", value: studioNames.joined(separator: "|")))
        }
        if let isFavorite { items.append(URLQueryItem(name: "IsFavorite", value: String(isFavorite))) }
        if let filters {
            items.append(URLQueryItem(name: "Filters", value: filters.joined(separator: ",")))
        }
        if let anyProviderIdEquals {
            items.append(URLQueryItem(name: "AnyProviderIdEquals", value: anyProviderIdEquals))
        }

        let fields = fields ?? JellyfinEndpoint.defaultFields
        items.append(URLQueryItem(name: "Fields", value: fields))
        items.append(URLQueryItem(name: "Recursive", value: "true"))
        // Default is true for Movie queries: Jellyfin folds BoxSet
        // members into a single representative row, even when the
        // collection isn't visible in the UI (it may have been created
        // silently from TMDB metadata). Always send false so each movie
        // appears on its own. Our "Collections" row uses a dedicated
        // IncludeItemTypes=BoxSet query and isn't affected.
        items.append(URLQueryItem(name: "CollapseBoxSetItems", value: "false"))

        return items
    }
}

private struct AuthenticateBody: Encodable, Sendable {
    let username: String
    let pw: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case pw = "Pw"
    }
}

private struct QuickConnectAuthBody: Encodable, Sendable {
    let secret: String

    enum CodingKeys: String, CodingKey {
        case secret = "Secret"
    }
}