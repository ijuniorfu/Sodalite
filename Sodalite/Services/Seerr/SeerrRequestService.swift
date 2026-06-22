import Foundation

protocol SeerrRequestServiceProtocol: Sendable {
    func createRequest(
        mediaType: SeerrMediaType,
        tmdbID: Int,
        seasons: [Int]?,
        serverID: Int?,
        profileID: Int?,
        rootFolder: String?,
        languageProfileID: Int?,
        tags: [Int]?
    ) async throws -> SeerrRequest

    func myRequests(userID: Int, take: Int, skip: Int) async throws -> SeerrRequestsResult

    /// Admin queue (all users, status-filtered); needs MANAGE_REQUESTS/ADMIN in `SeerrUser.permissions`. A revoked permission surfaces 403 as `APIError.unauthorized`.
    func allRequests(
        filter: SeerrRequestFilter,
        take: Int,
        skip: Int
    ) async throws -> SeerrRequestsResult

    @discardableResult
    func approveRequest(requestID: Int) async throws -> SeerrRequest

    @discardableResult
    func declineRequest(requestID: Int) async throws -> SeerrRequest

    func deleteRequest(requestID: Int) async throws

    @discardableResult
    func updateRequest(
        requestID: Int,
        body: SeerrRequestUpdateBody
    ) async throws -> SeerrRequest
}

@MainActor
final class SeerrRequestService: SeerrRequestServiceProtocol {
    private let client: SeerrClient

    init(client: SeerrClient) {
        self.client = client
    }

    func createRequest(
        mediaType: SeerrMediaType,
        tmdbID: Int,
        seasons: [Int]? = nil,
        serverID: Int? = nil,
        profileID: Int? = nil,
        rootFolder: String? = nil,
        languageProfileID: Int? = nil,
        tags: [Int]? = nil
    ) async throws -> SeerrRequest {
        let body = SeerrCreateRequestBody(
            mediaType: mediaType,
            mediaId: tmdbID,
            seasons: seasons,
            serverId: serverID,
            profileId: profileID,
            rootFolder: rootFolder,
            languageProfileId: languageProfileID,
            tags: tags
        )
        return try await client.request(
            endpoint: SeerrEndpoint.createRequest(body: body),
            responseType: SeerrRequest.self
        )
    }

    func myRequests(userID: Int, take: Int = 50, skip: Int = 0) async throws -> SeerrRequestsResult {
        try await client.request(
            endpoint: SeerrEndpoint.myRequests(userID: userID, take: take, skip: skip),
            responseType: SeerrRequestsResult.self
        )
    }

    func allRequests(
        filter: SeerrRequestFilter,
        take: Int = 50,
        skip: Int = 0
    ) async throws -> SeerrRequestsResult {
        try await client.request(
            endpoint: SeerrEndpoint.allRequests(filter: filter, take: take, skip: skip),
            responseType: SeerrRequestsResult.self
        )
    }

    @discardableResult
    func approveRequest(requestID: Int) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.approveRequest(requestID: requestID),
            responseType: SeerrRequest.self
        )
    }

    @discardableResult
    func declineRequest(requestID: Int) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.declineRequest(requestID: requestID),
            responseType: SeerrRequest.self
        )
    }

    func deleteRequest(requestID: Int) async throws {
        try await client.request(
            endpoint: SeerrEndpoint.deleteRequest(requestID: requestID)
        )
    }

    @discardableResult
    func updateRequest(
        requestID: Int,
        body: SeerrRequestUpdateBody
    ) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.updateRequest(requestID: requestID, body: body),
            responseType: SeerrRequest.self
        )
    }
}
