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

    /// Caps in-flight requests: unthrottled Home fan-out (60-90 reqs) trips a CDN/WAF in front of Jellyfin into tarpitting + timeout-nil rows (Sodalite#12/#14). 6 = browser-like per-host; per-client so Jellyfin/Seerr don't share a budget.
    private let inFlightLimiter = AsyncSemaphore(limit: 6)

    nonisolated init(session: URLSession? = nil) {
        // Cookies disabled: clients set auth manually (Seerr connect.sid, Jellyfin header). Auto-persisted cookies would reattach a stale connect.sid to the fresh /auth/jellyfin POST and earn a 401.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil

            // .reloadRevalidatingCacheData: conditional GET (If-None-Match) every request, so freshness == no-cache (server always authoritative) but unchanged metadata returns a 304 stub instead of multi-MB payload (Sodalite#12). 10MB mem (hot home rows) / 50MB disk (survives restart for cheap cold-launch revalidate). Images cache separately (AsyncCachedImage).
            config.urlCache = URLCache(
                memoryCapacity: 10 * 1024 * 1024,
                diskCapacity: 50 * 1024 * 1024,
                diskPath: "sodalite-http-cache"
            )
            config.requestCachePolicy = .reloadRevalidatingCacheData
            // Belt to inFlightLimiter: transport pool shouldn't exceed what the limiter admits.
            config.httpMaximumConnectionsPerHost = 6
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

        // wait() suspends without starting the request's timeout clock; permit balanced by the defer below on every exit path.
        try await inFlightLimiter.wait()
        defer { inFlightLimiter.signal() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces task cancellation as URLError(.cancelled); rethrow as CancellationError so callers ignore it instead of painting "Network connection failed".
            throw CancellationError()
        } catch let error as CancellationError {
            throw error
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
        var components: URLComponents?
        if let encodedPath = endpoint.percentEncodedPath {
            components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
            let basePath = baseURL.path
            let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            components?.percentEncodedPath = trimmedBase + encodedPath
        } else {
            components = URLComponents(url: baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: true)
        }
        components?.queryItems = endpoint.queryItems
        // URLComponents leaves "+" literal, but ASP.NET (Jellyfin) / Express (Seerr) decode it as space ("Disney+"→"Disney "). Spaces are already %20 here, so any remaining "+" is a real plus, escape to %2B.
        let encodedQuery = components?.percentEncodedQuery
        components?.percentEncodedQuery = encodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        guard let url = components?.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        // Endpoints may override the 30s default (e.g. fire-and-forget session-progress writes surviving a slow CDN hiccup, Sodalite#12).
        request.timeoutInterval = endpoint.timeoutInterval ?? 30

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
