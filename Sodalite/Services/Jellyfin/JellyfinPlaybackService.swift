import Foundation

protocol JellyfinPlaybackServiceProtocol: Sendable {
    var baseURL: URL? { get }
    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?) async throws -> PlaybackInfoResponse
    /// Live PlaybackInfo: AutoOpenLiveStream probes the stream (known codecs → DirectStream/copy, real LiveStreamId for tuner release); maxStreamingBitrate caps a transcode.
    func getLivePlaybackInfo(itemID: String, userID: String, profile: [String: Any]?, maxStreamingBitrate: Int) async throws -> PlaybackInfoResponse
    func reportPlaybackStart(_ report: PlaybackStartReport) async throws
    func reportPlaybackProgress(_ report: PlaybackProgressReport) async throws
    func reportPlaybackStopped(_ report: PlaybackStopReport) async throws
    func closeLiveStream(liveStreamID: String) async throws
    func stopActiveEncodings(playSessionID: String) async throws
    func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem]
    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem]
    func getEpisodeSegments(itemID: String) async throws -> EpisodeSegments
    func buildStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL?
    func buildAudioStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL?
    func buildSubtitleURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL?
    /// Server-rendered chapter image (from the "Chapter image extraction" task); `chapterIndex` indexes the original `Chapters` array. Nil without server/token, caller decodes a still itself.
    func buildChapterImageURL(itemID: String, chapterIndex: Int, imageTag: String, maxWidth: Int) -> URL?
    /// Searches server subtitle provider(s); `language` is 3-letter ISO 639-2. Empty = no results, throws on missing provider plugin (404/500).
    func searchRemoteSubtitles(itemID: String, language: String) async throws -> [RemoteSubtitleInfo]
    /// Server downloads `subtitleID` and attaches it to `itemID` as an external stream.
    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws
    /// Deletes external subtitle at `index`; needs subtitle-management rights.
    func deleteSubtitle(itemID: String, index: Int) async throws
    func buildTranscodeURL(relativePath: String) -> URL?
}

final class JellyfinPlaybackService: JellyfinPlaybackServiceProtocol {
    let client: JellyfinClient

    var baseURL: URL? { client.baseURL }

    init(client: JellyfinClient) {
        self.client = client
    }

    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]? = nil) async throws -> PlaybackInfoResponse {
        try await postPlaybackInfo(profile: profile) { payload in
            JellyfinEndpoint.playbackInfo(itemID: itemID, userID: userID, payload: payload)
        }
    }

    func getLivePlaybackInfo(itemID: String, userID: String, profile: [String: Any]? = nil, maxStreamingBitrate: Int) async throws -> PlaybackInfoResponse {
        try await postPlaybackInfo(profile: profile) { payload in
            JellyfinEndpoint.livePlaybackInfo(
                itemID: itemID,
                userID: userID,
                maxStreamingBitrate: maxStreamingBitrate,
                payload: payload
            )
        }
    }

    /// Routes through the shared HTTPClient (limiter, timeouts, APIError, cookie-free) not URLSession.shared; uses requestData + manual decode because DEBUG codec diagnostics need raw data.
    private func postPlaybackInfo(
        profile: [String: Any]?,
        endpoint: (JSONValue) throws -> JellyfinEndpoint
    ) async throws -> PlaybackInfoResponse {
        guard let baseURL = client.baseURL else { throw APIError.invalidURL }

        // Caller picks the profile (DirectPlayProfile.current() touches UIScreen, must run on the main actor); empty fallback shouldn't happen in practice.
        let deviceProfile = profile ?? [:]

        #if DEBUG
        if let dp = (deviceProfile["DirectPlayProfiles"] as? [[String: Any]])?.first {
            print("[PlaybackInfo] DirectPlay containers: \(dp["Container"] ?? "none")")
        }
        #endif

        let payload = try JSONValue(jsonObject: ["DeviceProfile": deviceProfile])
        let headers = [
            "Authorization": client.buildAuthHeader(),
            "Accept": "application/json",
        ]
        let (data, _) = try await client.httpClient.requestData(
            baseURL: baseURL,
            endpoint: try endpoint(payload),
            headers: headers
        )

        #if DEBUG
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sources = json["MediaSources"] as? [[String: Any]],
           let first = sources.first {
            print("[PlaybackInfo] Response container=\(first["Container"] ?? "nil"), directPlay=\(first["SupportsDirectPlay"] ?? "nil"), directStream=\(first["SupportsDirectStream"] ?? "nil")")
            if let reason = first["TranscodingUrl"] as? String, reason.contains("TranscodeReasons") {
                if let range = reason.range(of: "TranscodeReasons=") {
                    let reasons = reason[range.upperBound...]
                    print("[PlaybackInfo] TranscodeReasons: \(reasons.prefix(100))")
                }
            }
            // Source codec per stream: names the exact codec behind a live VideoCodecNotSupported so the copy list / FFmpegBuild decoder set extends deliberately.
            if let streams = first["MediaStreams"] as? [[String: Any]] {
                let desc = streams.map { s in
                    "\(s["Type"] ?? "?")=\(s["Codec"] ?? "?")\(s["Profile"].map { "(\($0))" } ?? "")"
                }.joined(separator: " ")
                print("[PlaybackInfo] Source streams: \(desc)")
            }
        }
        #endif

        do {
            return try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func reportPlaybackStart(_ report: PlaybackStartReport) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.sessionPlaying(report: report)
        )
    }

    func reportPlaybackProgress(_ report: PlaybackProgressReport) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.sessionProgress(report: report)
        )
    }

    func reportPlaybackStopped(_ report: PlaybackStopReport) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.sessionStopped(report: report)
        )
    }

    func closeLiveStream(liveStreamID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.closeLiveStream(liveStreamID: liveStreamID)
        )
    }

    /// Kill the transcode + its output for this device/play-session. A lost stop report otherwise keeps ffmpeg growing stream.ts until the disk fills, so every teardown fires this.
    func stopActiveEncodings(playSessionID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.stopActiveEncodings(
                deviceID: client.deviceID, playSessionID: playSessionID)
        )
    }

    func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.seasons(seriesID: seriesID, userID: userID),
            responseType: JellyfinItemsResponse.self
        )
        return response.items
    }

    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID),
            responseType: JellyfinItemsResponse.self
        )
        return response.items
    }

    /// Intro + outro markers in one call; empty struct on 404 (pre-10.10 without intro-skipper) or no segments.
    func getEpisodeSegments(itemID: String) async throws -> EpisodeSegments {
        do {
            let response: MediaSegmentsResponse = try await client.request(
                endpoint: JellyfinEndpoint.mediaSegments(itemID: itemID),
                responseType: MediaSegmentsResponse.self
            )
            return EpisodeSegments(
                intro: response.items.first(where: { $0.type == .intro }),
                outro: response.items.first(where: { $0.type == .outro })
            )
        } catch APIError.httpError(let status, _) where status == 404 {
            return EpisodeSegments(intro: nil, outro: nil)
        }
    }

    func searchRemoteSubtitles(itemID: String, language: String) async throws -> [RemoteSubtitleInfo] {
        try await client.request(
            endpoint: JellyfinEndpoint.remoteSearchSubtitles(itemID: itemID, language: language),
            responseType: [RemoteSubtitleInfo].self
        )
    }

    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.downloadRemoteSubtitle(itemID: itemID, subtitleID: subtitleID)
        )
    }

    func deleteSubtitle(itemID: String, index: Int) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.deleteSubtitle(itemID: itemID, index: index)
        )
    }

    func buildStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        let ext = container ?? "mp4"
        var components = URLComponents(url: baseURL.appendingPathComponent("/Videos/\(itemID)/stream.\(ext)"), resolvingAgainstBaseURL: true)
        var queryItems = [
            URLQueryItem(name: "MediaSourceId", value: mediaSourceID),
            URLQueryItem(name: "api_key", value: token),
        ]
        if isStatic {
            queryItems.append(URLQueryItem(name: "Static", value: "true"))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    func buildAudioStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        let ext = container ?? "mp3"
        var components = URLComponents(url: baseURL.appendingPathComponent("/Audio/\(itemID)/stream.\(ext)"), resolvingAgainstBaseURL: true)
        var queryItems = [
            URLQueryItem(name: "MediaSourceId", value: mediaSourceID),
            URLQueryItem(name: "api_key", value: token),
        ]
        if isStatic {
            queryItems.append(URLQueryItem(name: "Static", value: "true"))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    func buildSubtitleURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        let fmt = (format == "subrip") ? "srt" : format
        let path = "/Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/0/Stream.\(fmt)"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "api_key", value: token)]
        return components?.url
    }

    func buildChapterImageURL(itemID: String, chapterIndex: Int, imageTag: String, maxWidth: Int) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        let path = "/Items/\(itemID)/Images/Chapter/\(chapterIndex)"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        components?.queryItems = [
            // `tag` selects the render and doubles as a cache key (task re-run invalidates it).
            URLQueryItem(name: "tag", value: imageTag),
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: token),
        ]
        return components?.url
    }

    func buildTranscodeURL(relativePath: String) -> URL? {
        guard let baseURL = client.baseURL else { return nil }
        // TranscodingUrl is a path+query WITHOUT the server base path; URL(string:relativeTo:) would anchor at host root and drop a reverse-proxy subpath like "/jellyfin" (404). Splice onto the base components instead. String-assembled (NOT the percentEncoded setters, which fatalError on invalid chars and TranscodingUrl is server-controlled); URL(string:) returns nil instead.
        let trimmed = relativePath.hasPrefix("/") ? relativePath : "/\(relativePath)"
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            return nil
        }
        let encodedBasePath = components.percentEncodedPath
        let basePath = encodedBasePath.hasSuffix("/") ? String(encodedBasePath.dropLast()) : encodedBasePath
        components.percentEncodedPath = ""
        components.percentEncodedQuery = nil
        guard let root = components.url?.absoluteString else { return nil }
        let rootBase = root.hasSuffix("/") ? String(root.dropLast()) : root
        return URL(string: rootBase + basePath + trimmed)
    }
}
