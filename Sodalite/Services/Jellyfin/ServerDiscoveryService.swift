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
        let started = ContinuousClock.now

        let verdicts = await DiscoveryProbeRace.run(candidates: candidates) { [httpClient] url in
            await DiscoveryProbeRace.attempt(
                label: "jellyfin",
                url: url,
                describe: { (info: ServerDiscoveryInfo) in "\(info.serverName) v\(info.version)" }
            ) {
                let serverInfo = try await httpClient.request(
                    baseURL: url,
                    endpoint: JellyfinEndpoint.publicInfo,
                    headers: ["Accept": "application/json"],
                    responseType: JellyfinPublicServerInfo.self
                )
                // Only a decodable connection gates discovery; missing optional metadata must not.
                return ServerDiscoveryInfo(
                    id: serverInfo.id ?? "",
                    serverName: serverInfo.serverName ?? "Jellyfin",
                    version: serverInfo.version ?? ""
                )
            }
        }

        for (index, verdict) in verdicts.enumerated() {
            guard case .success(let info) = verdict else { continue }
            LogTap.shared.note("[discovery] jellyfin resolved \(candidates[index].absoluteString) in \(DiscoveryProbeRace.elapsedText(since: started))")
            return .success(url: candidates[index], serverInfo: info)
        }

        DiscoveryProbeRace.logUnanswered(
            label: "jellyfin",
            candidates: candidates,
            verdicts: verdicts,
            since: started
        )
        LogTap.shared.note("[discovery] jellyfin failed after \(DiscoveryProbeRace.elapsedText(since: started)) over \(candidates.count) candidate(s)")
        return .failure(DiscoveryProbeRace.aggregateError(verdicts))
    }

    // Widened from private to internal so SodaliteTests can exercise the URL-candidate branches directly.
    func buildCandidateURLs(from input: String) -> [URL] {
        var cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") {
            if let url = URL(string: cleaned) {
                var candidates = [url]
                // Add default Jellyfin ports only when no port + no path. Set via URLComponents, NOT string append (":8920" on https://host/jellyfin glues onto the path); a base path means reverse proxy where default ports don't apply.
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
                if let https = URL(string: "https://\(cleaned)") { candidates.append(https) }
                if let http = URL(string: "http://\(cleaned)") { candidates.append(http) }
            } else {
                // Default Jellyfin ports only without a path (":8920" on "ip/jellyfin" glues onto the path).
                if !cleaned.contains("/") {
                    if let url = URL(string: "https://\(cleaned):8920") { candidates.append(url) }
                    if let url = URL(string: "http://\(cleaned):8096") { candidates.append(url) }
                }
                // Also standard ports (reverse proxy).
                if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
                if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
            }
        } else if hasPort {
            // Appending another port yields host:port:port, which URL(string:) rejects.
            if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
            if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
        } else {
            // Standard ports first (likely reverse proxy), then Jellyfin ports.
            if let url = URL(string: "https://\(cleaned)") { candidates.append(url) }
            if let url = URL(string: "http://\(cleaned)") { candidates.append(url) }
            // Port variants only without a path (":8920" on "host/jellyfin" glues onto the path).
            if !cleaned.contains("/") {
                if let url = URL(string: "https://\(cleaned):8920") { candidates.append(url) }
                if let url = URL(string: "http://\(cleaned):8096") { candidates.append(url) }
            }
        }

        return candidates
    }
}
