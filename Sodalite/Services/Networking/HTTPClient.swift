import Foundation

protocol HTTPClientProtocol: Sendable {
    func request<T: Decodable>(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String],
        responseType: T.Type
    ) async throws -> T

    func request(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) async throws

    func requestData(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse)
}

final class HTTPClient: HTTPClientProtocol, @unchecked Sendable {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    nonisolated init(session: URLSession? = nil) {
        // Cookie handling is done manually by each client (Seerr sets
        // connect.sid, Jellyfin uses header-based auth). If we let
        // URLSession.shared auto-persist cookies in HTTPCookieStorage,
        // a stale connect.sid from an expired Seerr session keeps
        // getting attached to every request, including the fresh
        // /auth/jellyfin POST, which Seerr then rejects with 401
        // before looking at the credentials. Using a dedicated session
        // with cookies disabled keeps our manual header the single
        // source of truth.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil

            // Response caching with always-revalidate policy.
            // The earlier hard-disable was a heavy hammer for one
            // specific symptom: Jellyfin /Items responses being
            // served stale across app restarts because URLSession
            // honoured the server's Cache-Control max-age without
            // checking back. The fix isn't "no caching" — it's
            // "always ask the server but skip the body if nothing
            // changed". `.reloadRevalidatingCacheData` makes
            // URLSession send a conditional GET (If-None-Match /
            // If-Modified-Since) on every request; the server
            // replies 304 + ~200 bytes if the resource is unchanged
            // and URLSession serves the cached body, otherwise 200
            // + full payload and the cache is rewritten. The
            // freshness guarantee is identical to the no-cache
            // policy (server is the authority on every request);
            // the win is body bytes on unchanged metadata, which
            // on a 1 PB CDN-backed Jellyfin (Sodalite#12) trims
            // /Items/Latest, /Users/Me, /Items/{id} from multi-MB
            // payloads to a 304 stub.
            //
            // Sizes match a typical Jellyfin metadata working set:
            // 10 MB memory keeps the hot rows of the home page
            // resident; 50 MB disk survives app restarts so a cold
            // launch can revalidate (cheap) instead of refetching
            // (expensive). Image caching is still separate
            // (AsyncCachedImage on its own session).
            config.urlCache = URLCache(
                memoryCapacity: 10 * 1024 * 1024,
                diskCapacity: 50 * 1024 * 1024,
                diskPath: "sodalite-http-cache"
            )
            config.requestCachePolicy = .reloadRevalidatingCacheData
            self.session = URLSession(configuration: config)
        }

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func request<T: Decodable>(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String],
        responseType: T.Type
    ) async throws -> T {
        let (data, _) = try await requestData(baseURL: baseURL, endpoint: endpoint, headers: headers)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func request(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) async throws {
        let _ = try await requestData(baseURL: baseURL, endpoint: endpoint, headers: headers)
    }

    func requestData(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try buildRequest(baseURL: baseURL, endpoint: endpoint, headers: headers)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw APIError.timeout
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .cannotConnectToHost {
            throw APIError.serverUnreachable
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return (data, httpResponse)
        case 401:
            throw APIError.unauthorized(message: APIError.extractErrorMessage(from: data))
        default:
            throw APIError.httpError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    private func buildRequest(
        baseURL: URL,
        endpoint: APIEndpoint,
        headers: [String: String]
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: true)
        components?.queryItems = endpoint.queryItems

        guard let url = components?.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = 30

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body = endpoint.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        return request
    }
}

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        _encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
