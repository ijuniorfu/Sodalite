import Foundation

protocol JellyfinPlaybackServiceProtocol: Sendable {
    var baseURL: URL? { get }
    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?) async throws -> PlaybackInfoResponse
    /// Live-channel PlaybackInfo: opens + probes the live stream
    /// (`AutoOpenLiveStream=true`) so the source codecs are known (enabling
    /// DirectStream / codec-copy when compatible) and a real `LiveStreamId`
    /// comes back for tuner release. `maxStreamingBitrate` caps any transcode.
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

    /// Routes through the shared HTTPClient (in-flight limiter, timeout
    /// regime, APIError mapping, cookie-free session) instead of
    /// URLSession.shared; raw response data is still needed for the
    /// DEBUG codec diagnostics, hence requestData + manual decode.
    private func postPlaybackInfo(
        profile: [String: Any]?,
        endpoint: (JSONValue) throws -> JellyfinEndpoint
    ) async throws -> PlaybackInfoResponse {
        guard let baseURL = client.baseURL else { throw APIError.invalidURL }

        // The caller (PlayerViewModel / DetailViewModel) is responsible
        // for picking the right profile, since DirectPlayProfile.current()
        // touches UIScreen and must run on the main actor. Fall back to
        // an empty profile only if no caller hands one in (shouldn't
        // happen in practice).
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
            // Source codec per stream. Decisive for live channels the server
            // wants to re-encode (VideoCodecNotSupported): names the exact
            // codec so the copy list / FFmpegBuild decoder set can be
            // extended deliberately instead of guessing.
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

    /// Kill the server-side transcode job for this device + play session
    /// and delete its output files. Live transcodes write an endlessly
    /// growing stream.ts; a job whose stop report gets lost keeps writing
    /// until the server disk fills, so every teardown fires this
    /// explicitly (same call jellyfin-web makes on stop).
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

    /// Ask the server for intro + outro markers on an item in one call.
    /// Returns an empty struct if the server doesn't expose the endpoint
    /// (Jellyfin pre-10.10 without the intro-skipper plugin → 404) or if
    /// no matching segments were detected.
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

    func buildTranscodeURL(relativePath: String) -> URL? {
        guard let baseURL = client.baseURL else { return nil }
        // Jellyfin returns TranscodingUrl as a path with query string, e.g.
        // "/videos/<id>/main.m3u8?DeviceId=...&MediaSourceId=...&api_key=..."
        // and that path does NOT include the server's base path. Resolving
        // it with URL(string:relativeTo:) would anchor at the host root and
        // drop a reverse-proxy subpath like "/jellyfin", 404ing every
        // transcode session on such setups. Splice path and query onto the
        // base URL's components instead.
        let trimmed = relativePath.hasPrefix("/") ? relativePath : "/\(relativePath)"
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            return nil
        }
        let pathAndQuery = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let encodedBasePath = components.percentEncodedPath
        let basePath = encodedBasePath.hasSuffix("/") ? String(encodedBasePath.dropLast()) : encodedBasePath
        components.percentEncodedPath = basePath + String(pathAndQuery[0])
        components.percentEncodedQuery = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : nil
        return components.url
    }
}
