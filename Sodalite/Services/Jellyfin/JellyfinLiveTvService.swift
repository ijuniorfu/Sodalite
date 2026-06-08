import Foundation

protocol JellyfinLiveTvServiceProtocol: Sendable {
    func getChannels(userID: String, startIndex: Int, limit: Int) async throws -> LiveTvChannelsResponse
    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram]
    func getGuideInfo() async throws -> JellyfinGuideInfo
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
                channelIDs: channelIDs, userID: userID, minStartDate: start, maxStartDate: end),
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
}
