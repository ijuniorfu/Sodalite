import Foundation

@MainActor
final class JellyfinClient {
    let httpClient: HTTPClientProtocol
    /// Stable per-install device id (auth header + stream URLs). Exposed because /Videos/ActiveEncodings kills transcodes by (DeviceId, PlaySessionId).
    private(set) var deviceID: String
    private let appVersion: String

    var baseURL: URL?
    var accessToken: String?

    init(httpClient: HTTPClientProtocol = HTTPClient()) {
        self.httpClient = httpClient
        self.deviceID = Self.getOrCreateDeviceID()
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func request<T: Decodable>(
        endpoint: APIEndpoint,
        responseType: T.Type
    ) async throws -> T {
        guard let baseURL else { throw APIError.invalidURL }
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        return try await httpClient.request(
            baseURL: baseURL,
            endpoint: endpoint,
            headers: headers,
            responseType: responseType
        )
    }

    /// Variant with a caller-supplied decoder, needed for Live TV whose date format the shared `.iso8601` decoder can't parse.
    func request<T: Decodable>(
        endpoint: APIEndpoint,
        responseType: T.Type,
        decoder: JSONDecoder
    ) async throws -> T {
        guard let baseURL else { throw APIError.invalidURL }
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        let (data, _) = try await httpClient.requestData(
            baseURL: baseURL, endpoint: endpoint, headers: headers)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Mirror HTTPClient.request: localized message instead of raw DecodingError.
            throw APIError.decodingError(error)
        }
    }

    func request(endpoint: APIEndpoint) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        try await httpClient.request(
            baseURL: baseURL,
            endpoint: endpoint,
            headers: headers
        )
    }

    func buildAuthHeader() -> String {
        buildMediaBrowserHeader(includeToken: true)
    }

    /// Single owner of the MediaBrowser header so client/device/version can't drift between the engine device profile and per-request headers.
    private func buildMediaBrowserHeader(includeToken: Bool) -> String {
        var authParts = [
            "Client=\"Sodalite\"",
            "Device=\"Apple TV\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"\(appVersion)\"",
        ]
        if includeToken, let token = accessToken {
            authParts.append("Token=\"\(token)\"")
        }
        return "MediaBrowser \(authParts.joined(separator: ", "))"
    }

    private func buildHeaders(requiresAuth: Bool) -> [String: String] {
        [
            "Authorization": buildMediaBrowserHeader(includeToken: requiresAuth),
            "Accept": "application/json",
        ]
    }

    private static func getOrCreateDeviceID() -> String {
        let key = "Sodalite_DeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }
}
