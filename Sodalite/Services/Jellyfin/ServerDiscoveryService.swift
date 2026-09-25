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

private struct DiscoveredServer: Sendable {
    let info: ServerDiscoveryInfo
    let url: URL
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
                describe: { (found: DiscoveredServer) in "\(found.info.serverName) v\(found.info.version)" }
            ) {
                let endpoint = JellyfinEndpoint.publicInfo
                let (data, response) = try await httpClient.requestData(
                    baseURL: url,
                    endpoint: endpoint,
                    headers: ["Accept": "application/json"]
                )
                let serverInfo: JellyfinPublicServerInfo
                do {
                    serverInfo = try JSONDecoder().decode(JellyfinPublicServerInfo.self, from: data)
                } catch {
                    throw APIError.decodingError(error)
                }
                // Only a decodable connection gates discovery; missing optional metadata must not.
                let info = ServerDiscoveryInfo(
                    id: serverInfo.id ?? "",
                    serverName: serverInfo.serverName ?? "Jellyfin",
                    version: serverInfo.version ?? ""
                )
                return DiscoveredServer(
                    info: info,
                    url: Self.upgradedBaseURL(candidate: url, finalURL: response.url, endpointPath: endpoint.path)
                )
            }
        }

        for verdict in verdicts {
            guard case .success(let found) = verdict else { continue }
            LogTap.shared.note("[discovery] jellyfin resolved \(found.url.absoluteString) in \(DiscoveryProbeRace.elapsedText(since: started))")
            return .success(url: found.url, serverInfo: found.info)
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

    /// The address to store for a candidate, given where its probe actually ended up.
    ///
    /// A server entered as `http://` behind a proxy that upgrades to https passed discovery on the
    /// redirect, but the pre-redirect URL was stored, and every later request lost its credentials
    /// on that hop (audit NETWORK-4). Only that one hop is adopted: same host, http to https, and the
    /// endpoint still at the end of the path. Any other redirect keeps the address that was typed.
    nonisolated static func upgradedBaseURL(candidate: URL, finalURL: URL?, endpointPath: String) -> URL {
        guard let finalURL,
              candidate.scheme?.lowercased() == "http", finalURL.scheme?.lowercased() == "https",
              let candidateHost = candidate.host(percentEncoded: false)?.lowercased(),
              candidateHost == finalURL.host(percentEncoded: false)?.lowercased(),
              var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
              components.path.hasSuffix(endpointPath)
        else { return candidate }
        components.path = String(components.path.dropLast(endpointPath.count))
        components.query = nil
        components.fragment = nil
        return components.url ?? candidate
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
