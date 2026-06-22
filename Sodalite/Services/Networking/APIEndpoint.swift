import Foundation

protocol APIEndpoint: Sendable {
    var path: String { get }
    var method: HTTPMethod { get }
    var queryItems: [URLQueryItem]? { get }
    var body: (any Encodable & Sendable)? { get }
    var requiresAuth: Bool { get }
    /// Non-nil = already-percent-encoded path used verbatim, bypassing `appendingPathComponent` which double-encodes `%` (e.g. subtitle id containing `/`). Must start with "/" and exclude the base URL path prefix.
    var percentEncodedPath: String? { get }
    /// Per-endpoint timeout override; nil = HTTPClient default (30s). Raise for fire-and-forget writes surviving a slow CDN hiccup.
    var timeoutInterval: TimeInterval? { get }
}

extension APIEndpoint {
    var queryItems: [URLQueryItem]? { nil }
    var percentEncodedPath: String? { nil }
    var body: (any Encodable & Sendable)? { nil }
    var requiresAuth: Bool { true }
    var timeoutInterval: TimeInterval? { nil }
}
