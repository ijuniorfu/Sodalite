import Foundation

struct JellyfinServer: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let version: String?

    init(id: String, name: String, url: URL, version: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.version = version
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
