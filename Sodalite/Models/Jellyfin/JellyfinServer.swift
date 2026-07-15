import Foundation

/// A Jellyfin server with up to two URL slots. `internalURL` is the home-LAN
/// address, `externalURL` the reverse-proxy/public one; at least one is set.
/// Custom Codable migrates legacy single-`url` blobs (keychain, CloudKit) by
/// classifying the host, and keeps emitting the legacy `url` key so older
/// builds can still decode synced records.
struct JellyfinServer: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    var internalURL: URL?
    var externalURL: URL?
    let version: String?

    /// Primary URL for display and single-URL call sites; live routing goes
    /// through ServerRouteResolver instead.
    var url: URL { internalURL ?? externalURL! }

    init(id: String, name: String, internalURL: URL?, externalURL: URL?, version: String? = nil) {
        precondition(internalURL != nil || externalURL != nil, "server needs at least one URL")
        self.id = id
        self.name = name
        self.internalURL = internalURL
        self.externalURL = externalURL
        self.version = version
    }

    /// Legacy convenience: classifies the single address into the matching slot.
    init(id: String, name: String, url: URL, version: String? = nil) {
        if ServerURLClassifier.isInternal(url) {
            self.init(id: id, name: name, internalURL: url, externalURL: nil, version: version)
        } else {
            self.init(id: id, name: name, internalURL: nil, externalURL: url, version: version)
        }
    }

    func url(for route: ServerRoute) -> URL? {
        switch route {
        case .internal: internalURL
        case .external: externalURL
        }
    }

    /// Synchronous best guess for first-frame client setup; the async resolver corrects it.
    func preferredURL(lastKnown: ServerRoute?) -> URL {
        if let lastKnown, let match = url(for: lastKnown) { return match }
        return url
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, internalURL, externalURL, version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let version = try container.decodeIfPresent(String.self, forKey: .version)
        let internalURL = try container.decodeIfPresent(URL.self, forKey: .internalURL)
        let externalURL = try container.decodeIfPresent(URL.self, forKey: .externalURL)
        if internalURL != nil || externalURL != nil {
            self.init(id: id, name: name, internalURL: internalURL, externalURL: externalURL, version: version)
        } else {
            let legacy = try container.decode(URL.self, forKey: .url)
            self.init(id: id, name: name, url: legacy, version: version)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(internalURL, forKey: .internalURL)
        try container.encodeIfPresent(externalURL, forKey: .externalURL)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(version, forKey: .version)
    }
}

struct JellyfinPublicServerInfo: Codable, Sendable {
    // The Jellyfin PublicSystemInfo schema marks Id/ServerName/Version nullable with no required
    // constraint; reverse-proxied, freshly-installed, or forked servers can omit them. Modeling
    // them non-optional rejected those valid servers and blocked discovery, so they are optional.
    let id: String?
    let serverName: String?
    let version: String?
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
    }
}
