import Foundation

@MainActor
final class SeerrClient {
    let httpClient: HTTPClientProtocol

    var baseURL: URL?
    var sessionCookie: String?

    private let decoder: JSONDecoder

    init(httpClient: HTTPClientProtocol = HTTPClient()) {
        self.httpClient = httpClient

        // Decode converts snake_case (TMDB-shaped responses: poster_path, vote_average). POST bodies stay camelCase (HTTPClient.encoder); the API rejects snake_case bodies with HTTP 500.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func request<T: Decodable>(
        endpoint: APIEndpoint,
        responseType: T.Type
    ) async throws -> T {
        guard let baseURL else { throw APIError.invalidURL }
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        let (data, _) = try await httpClient.requestData(
            baseURL: baseURL,
            endpoint: endpoint,
            headers: headers
        )
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func request(endpoint: APIEndpoint) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        _ = try await httpClient.requestData(
            baseURL: baseURL,
            endpoint: endpoint,
            headers: headers
        )
    }

    func requestWithResponse<T: Decodable>(
        endpoint: APIEndpoint,
        responseType: T.Type
    ) async throws -> (T, HTTPURLResponse) {
        guard let baseURL else { throw APIError.invalidURL }
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        let (data, response) = try await httpClient.requestData(
            baseURL: baseURL,
            endpoint: endpoint,
            headers: headers
        )
        do {
            let value = try decoder.decode(T.self, from: data)
            return (value, response)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Honor `requiresAuth` so the cookie isn't attached to the /auth/jellyfin POST, where a stale connect.sid would poison the fresh login.
    private func buildHeaders(requiresAuth: Bool) -> [String: String] {
        var headers: [String: String] = [:]
        headers["Accept"] = "application/json"
        if requiresAuth, let sessionCookie {
            headers["Cookie"] = sessionCookie
        }
        return headers
    }

    func extractSessionCookie(from response: HTTPURLResponse) -> String? {
        guard let baseURL,
              let headerFields = response.allHeaderFields as? [String: String]
        else { return nil }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: baseURL)
        guard let sessionCookie = cookies.first(where: { $0.name == "connect.sid" }) else {
            return nil
        }
        return "\(sessionCookie.name)=\(sessionCookie.value)"
    }
}
