import Foundation

nonisolated struct SeerrServerInfo: Codable, Sendable {
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
        let started = ContinuousClock.now

        let verdicts = await DiscoveryProbeRace.run(candidates: candidates) { [decoder, httpClient] url in
            await DiscoveryProbeRace.attempt(
                label: "seerr",
                url: url,
                describe: { (info: SeerrServerInfo) in "v\(info.version)" }
            ) {
                let (data, _) = try await httpClient.requestData(
                    baseURL: url,
                    endpoint: SeerrEndpoint.status,
                    headers: ["Accept": "application/json"]
                )
                return try decoder.decode(SeerrServerInfo.self, from: data)
            }
        }

        for (index, verdict) in verdicts.enumerated() {
            guard case .success(let info) = verdict else { continue }
            LogTap.shared.note("[discovery] seerr resolved \(candidates[index].absoluteString) in \(DiscoveryProbeRace.elapsedText(since: started))")
            return .success(url: candidates[index], info: info)
        }

        DiscoveryProbeRace.logUnanswered(
            label: "seerr",
            candidates: candidates,
            verdicts: verdicts,
            since: started
        )
        LogTap.shared.note("[discovery] seerr failed after \(DiscoveryProbeRace.elapsedText(since: started)) over \(candidates.count) candidate(s)")
        return .failure(DiscoveryProbeRace.aggregateError(verdicts))
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
