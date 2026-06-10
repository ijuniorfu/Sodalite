import Foundation

protocol JellyfinLiveTvServiceProtocol: Sendable {
    func getChannels(userID: String, startIndex: Int, limit: Int) async throws -> LiveTvChannelsResponse
    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram]
    func getGuideInfo() async throws -> JellyfinGuideInfo
    /// Mark/unmark a channel as favorite. Channels are `BaseItemDto`, so this
    /// reuses the generic FavoriteItems endpoint media items already use.
    func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws
    /// `isInProgress` nil fetches everything; true/false filters
    /// server-side (active-recording detection, see the endpoint note).
    func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem]
    func getTimers() async throws -> [LiveTvTimer]
    func getSeriesTimers() async throws -> [LiveTvSeriesTimer]
    func createTimer(programID: String) async throws
    func cancelTimer(timerID: String) async throws
    func createSeriesTimer(programID: String) async throws
    func cancelSeriesTimer(timerID: String) async throws
}

final class JellyfinLiveTvService: JellyfinLiveTvServiceProtocol {
    private let client: JellyfinClient

    init(client: JellyfinClient) {
        self.client = client
    }

    func getChannels(userID: String, startIndex: Int, limit: Int) async throws -> LiveTvChannelsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.liveTvChannels(userID: userID, startIndex: startIndex, limit: limit),
            responseType: LiveTvChannelsResponse.self,
            decoder: .jellyfinLiveTv
        )
    }

    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] {
        guard !channelIDs.isEmpty else { return [] }
        let response: LiveTvProgramsResponse = try await client.request(
            endpoint: JellyfinEndpoint.liveTvPrograms(
                channelIDs: channelIDs, userID: userID, minEndDate: start, maxStartDate: end),
            responseType: LiveTvProgramsResponse.self,
            decoder: .jellyfinLiveTv
        )
        return response.items
    }

    func getGuideInfo() async throws -> JellyfinGuideInfo {
        try await client.request(
            endpoint: JellyfinEndpoint.liveTvGuideInfo,
            responseType: JellyfinGuideInfo.self,
            decoder: .jellyfinLiveTv
        )
    }

    func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws {
        let endpoint: JellyfinEndpoint = isFavorite
            ? .markFavorite(userID: userID, itemID: channelID)
            : .unmarkFavorite(userID: userID, itemID: channelID)
        try await client.request(endpoint: endpoint)
    }

    func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem] {
        // Recordings are plain BaseItemDtos; the standard item decoder
        // applies (JellyfinItemsResponse), not the lenient LiveTv one.
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.liveTvRecordings(userID: userID, isInProgress: isInProgress),
            responseType: JellyfinItemsResponse.self
        )
        return response.items
    }

    func getTimers() async throws -> [LiveTvTimer] {
        let response: LiveTvTimersResponse = try await client.request(
            endpoint: JellyfinEndpoint.liveTvTimers,
            responseType: LiveTvTimersResponse.self,
            decoder: .jellyfinLiveTv
        )
        return response.items
    }

    func getSeriesTimers() async throws -> [LiveTvSeriesTimer] {
        let response: LiveTvSeriesTimersResponse = try await client.request(
            endpoint: JellyfinEndpoint.liveTvSeriesTimers,
            responseType: LiveTvSeriesTimersResponse.self,
            decoder: .jellyfinLiveTv
        )
        return response.items
    }

    /// GET the server-side defaults for this program and POST them back
    /// unchanged. The defaults payload (TimerInfoDto) carries pre/post
    /// padding, priority, and the program/channel binding; round-tripping
    /// it avoids re-modeling every field.
    func createTimer(programID: String) async throws {
        let defaults: JSONValue = try await client.request(
            endpoint: JellyfinEndpoint.liveTvTimerDefaults(programID: programID),
            responseType: JSONValue.self,
            decoder: .jellyfinLiveTv
        )
        try await client.request(
            endpoint: JellyfinEndpoint.createLiveTvTimer(payload: defaults)
        )
    }

    func cancelTimer(timerID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.deleteLiveTvTimer(timerID: timerID)
        )
    }

    /// Same defaults round-trip; POSTing to /LiveTv/SeriesTimers turns
    /// the program defaults into a series rule (record every episode).
    func createSeriesTimer(programID: String) async throws {
        let defaults: JSONValue = try await client.request(
            endpoint: JellyfinEndpoint.liveTvTimerDefaults(programID: programID),
            responseType: JSONValue.self,
            decoder: .jellyfinLiveTv
        )
        try await client.request(
            endpoint: JellyfinEndpoint.createLiveTvSeriesTimer(payload: defaults)
        )
    }

    func cancelSeriesTimer(timerID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.deleteLiveTvSeriesTimer(timerID: timerID)
        )
    }
}
