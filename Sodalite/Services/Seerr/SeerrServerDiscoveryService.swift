import Foundation

struct SeerrServerInfo: Codable, Sendable {
    let version: String
}

enum SeerrServerDiscoveryResult: Sendable {
    case success(url: URL, info: SeerrServerInfo)
    case failure(APIError)
}

protocol SeerrServerDiscoveryServiceProtocol: Sendable {
    func discoverServer(input: String) async -> SeerrServerDiscoveryResult
}

final class SeerrServerDiscoveryService: SeerrServerDiscoveryServiceProtocol {
    private let httpClient: HTTPClientProtocol
    private let decoder: JSONDecoder

    nonisolated init(httpClient: HTTPClientProtocol = HTTPClient()) {
        self.httpClient = httpClient
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func discoverServer(input: String) async -> SeerrServerDiscoveryResult {
        let candidates = buildCandidateURLs(from: input)

        // A candidate that connects but isn't Jellyseerr is a better diagnostic than "unreachable"; prefer the first such error.
        var firstProtocolError: APIError?

        for url in candidates {
            do {
                let (data, _) = try await httpClient.requestData(
                    baseURL: url,
                    endpoint: SeerrEndpoint.status,
                    headers: ["Accept": "application/json"]
                )
                let info = try decoder.decode(SeerrServerInfo.self, from: data)
                return .success(url: url, info: info)
            } catch is CancellationError {
                return .failure(.serverUnreachable)
            } catch let error as DecodingError {
                if firstProtocolError == nil { firstProtocolError = .decodingError(error) }
                continue
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

        if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") {
            guard let url = URL(string: cleaned) else { return [] }
            var candidates = [url]
            // Port 5055 fallback only for plain-HTTP, no port, no path. Via URLComponents, NOT string append (":5055" on http://host/jellyseerr glues onto the path).
            if url.port == nil, cleaned.hasPrefix("http://"),
               url.path.isEmpty || url.path == "/",
               var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                components.port = 5055
                if let withPort = components.url {
                    candidates.append(withPort)
                }
            }
            return candidates
        }

        let isIPAddress = cleaned.range(
            of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#,
            options: .regularExpression
        ) != nil
        let hasPort = cleaned.contains(":")

        var candidates: [URL] = []

        if isIPAddress {
            if hasPort {
                if let https = URL(string: "https://\(cleaned)") { candidates.append(https) }
                if let http = URL(string: "http://\(cleaned)") { candidates.append(http) }
            } else {
                // Port variants only without a path (":5055" on an IP+path glues onto the path).
                if !cleaned.contains("/") {
                    if let url = URL(string: "http://\(cleaned):5055") { candidates.append(url) }
                    if let url = URL(string: "https://\(cleaned):5055") { candidates.append(url) }
                }
                if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
                if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
            }
        } else if hasPort {
            // Appending another port yields host:port:port, which URL(string:) rejects.
            if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
            if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
        } else {
            if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
            if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
            // Port variants only without a path (":5055" on "host/jellyseerr" glues onto the path).
            if !cleaned.contains("/") {
                if let url = URL(string: "http://\(cleaned):5055") { candidates.append(url) }
                if let url = URL(string: "https://\(cleaned):5055") { candidates.append(url) }
            }
        }

        return candidates
    }
}
