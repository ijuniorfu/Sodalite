import Foundation

protocol ServerDiscoveryServiceProtocol: Sendable {
    func discoverServer(input: String) async -> ServerDiscoveryResult
}

enum ServerDiscoveryResult: Sendable {
    case success(url: URL, serverInfo: ServerDiscoveryInfo)
    case failure(APIError)
}

struct ServerDiscoveryInfo: Sendable {
    let id: String
    let serverName: String
    let version: String
}

final class ServerDiscoveryService: ServerDiscoveryServiceProtocol {
    private let httpClient: HTTPClientProtocol

    nonisolated init(httpClient: HTTPClientProtocol = HTTPClient()) {
        self.httpClient = httpClient
    }

    func discoverServer(input: String) async -> ServerDiscoveryResult {
        let candidates = buildCandidateURLs(from: input)

        // A candidate that connects but doesn't speak Jellyfin (captive
        // portal, proxy login page, wrong service) is a better diagnostic
        // than "unreachable"; remember the first such error and prefer
        // it for the failure result.
        var firstProtocolError: APIError?

        for url in candidates {
            do {
                let serverInfo = try await httpClient.request(
                    baseURL: url,
                    endpoint: JellyfinEndpoint.publicInfo,
                    headers: ["Accept": "application/json"],
                    responseType: JellyfinPublicServerInfo.self
                )
                let info = ServerDiscoveryInfo(
                    id: serverInfo.id,
                    serverName: serverInfo.serverName,
                    version: serverInfo.version
                )
                return .success(url: url, serverInfo: info)
            } catch is CancellationError {
                // The caller abandoned the probe; don't keep hammering
                // the remaining candidates.
                return .failure(.serverUnreachable)
            } catch let error as APIError {
                switch error {
                case .decodingError, .httpError, .invalidResponse, .unauthorized:
                    if firstProtocolError == nil { firstProtocolError = error }
                default:
                    break
                }
                continue
            } catch {
                continue
            }
        }

        return .failure(firstProtocolError ?? .serverUnreachable)
    }

    private func buildCandidateURLs(from input: String) -> [URL] {
        var cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // If already a full URL with scheme, try it directly + with default ports
        if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") {
            if let url = URL(string: cleaned) {
                var candidates = [url]
                // If no port is specified and the URL has no path, also
                // try the default Jellyfin ports. Set the port through
                // URLComponents: appending ":8920" to the string glues
                // the port onto the path for inputs like
                // https://host/jellyfin (yielding /jellyfin:8920, a
                // candidate that can never succeed), and a URL with a
                // base path is a reverse-proxy setup where the default
                // ports don't apply anyway.
                if url.port == nil, url.path.isEmpty || url.path == "/",
                   var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                    components.port = cleaned.hasPrefix("https://") ? 8920 : 8096
                    if let withPort = components.url {
                        candidates.append(withPort)
                    }
                }
                return candidates
            }
            return []
        }

        let isIPAddress = cleaned.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#, options: .regularExpression) != nil
        let hasPort = cleaned.contains(":")

        var candidates: [URL] = []

        if isIPAddress {
            if hasPort {
                // IP with explicit port: try both schemes
                if let https = URL(string: "https://\(cleaned)") { candidates.append(https) }
                if let http = URL(string: "http://\(cleaned)") { candidates.append(http) }
            } else {
                // IP without port: try default Jellyfin ports
                // HTTPS with Jellyfin HTTPS port
                if let url = URL(string: "https://\(cleaned):8920") { candidates.append(url) }
                // HTTP with Jellyfin HTTP port
                if let url = URL(string: "http://\(cleaned):8096") { candidates.append(url) }
                // Also try standard ports (reverse proxy setup)
                if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
                if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
            }
        } else if hasPort {
            // Domain with explicit port: appending another port would
            // produce host:port:port, which URL(string:) rejects.
            if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
            if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
        } else {
            // Domain name: try standard ports first (likely reverse proxy), then Jellyfin ports
            if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
            if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
            // Port variants only make sense without a path; appending
            // ":8920" to "host/jellyfin" glues the port onto the path.
            if !cleaned.contains("/") {
                if let url = URL(string: "https://\(cleaned):8920") { candidates.append(url) }
                if let url = URL(string: "http://\(cleaned):8096") { candidates.append(url) }
            }
        }

        return candidates
    }
}
