import Foundation

protocol APIEndpoint: Sendable {
    var path: String { get }
    var method: HTTPMethod { get }
    var queryItems: [URLQueryItem]? { get }
    var body: (any Encodable & Sendable)? { get }
    var requiresAuth: Bool { get }
    /// When non-nil, this path is treated as ALREADY percent-encoded and
    /// used verbatim (via URLComponents.percentEncodedPath), bypassing
    /// `appendingPathComponent` which would double-encode `%`. Use only
    /// when a path segment contains characters that must be single-encoded
    /// (e.g. a provider-scoped subtitle id containing `/`). Must start with
    /// "/" and NOT include the base URL's own path prefix.
    var percentEncodedPath: String? { get }
    /// Per-endpoint URLRequest timeout override. `nil` falls back to
    /// the HTTPClient default (30 s). Set explicitly on endpoints
    /// where a 30 s ceiling is too aggressive, e.g. fire-and-forget
    /// session-progress writes that must survive a slow CDN hiccup.
    var timeoutInterval: TimeInterval? { get }
}

extension APIEndpoint {
    var queryItems: [URLQueryItem]? { nil }
    var percentEncodedPath: String? { nil }
    var body: (any Encodable & Sendable)? { nil }
    var requiresAuth: Bool { true }
    var timeoutInterval: TimeInterval? { nil }
}
