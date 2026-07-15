import Foundation

/// Same dual-URL shape as JellyfinServer (see there for the Codable migration rationale).
struct SeerrServer: Codable, Sendable, Identifiable, Equatable {
    let id: String
    var internalURL: URL?
    var externalURL: URL?

    var url: URL { internalURL ?? externalURL! }

    init(id: String = UUID().uuidString, internalURL: URL?, externalURL: URL?) {
        precondition(internalURL != nil || externalURL != nil, "server needs at least one URL")
        self.id = id
        self.internalURL = internalURL
        self.externalURL = externalURL
    }

    init(id: String = UUID().uuidString, url: URL) {
        if ServerURLClassifier.isInternal(url) {
            self.init(id: id, internalURL: url, externalURL: nil)
        } else {
            self.init(id: id, internalURL: nil, externalURL: url)
        }
    }

    func url(for route: ServerRoute) -> URL? {
        switch route {
        case .internal: internalURL
        case .external: externalURL
        }
    }

    func preferredURL(lastKnown: ServerRoute?) -> URL {
        if let lastKnown, let match = url(for: lastKnown) { return match }
        return url
    }

    enum CodingKeys: String, CodingKey { case id, url, internalURL, externalURL }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let internalURL = try container.decodeIfPresent(URL.self, forKey: .internalURL)
        let externalURL = try container.decodeIfPresent(URL.self, forKey: .externalURL)
        if internalURL != nil || externalURL != nil {
            self.init(id: id, internalURL: internalURL, externalURL: externalURL)
        } else {
            self.init(id: id, url: try container.decode(URL.self, forKey: .url))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(internalURL, forKey: .internalURL)
        try container.encodeIfPresent(externalURL, forKey: .externalURL)
        try container.encode(url, forKey: .url)
    }
}
