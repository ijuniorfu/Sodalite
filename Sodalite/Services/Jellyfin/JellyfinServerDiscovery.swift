import Foundation

struct DiscoveredServer: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let address: URL
}

protocol JellyfinServerDiscoveryProtocol: Sendable {
    func discover() -> AsyncStream<DiscoveredServer>
}

final class JellyfinServerDiscovery: JellyfinServerDiscoveryProtocol {
    nonisolated init() {}

    // Jellyfin's UDP discovery reply. PascalCase keys; EndpointAddress is ignored (null in practice).
    private struct Reply: Decodable {
        let address: String
        let id: String
        let name: String
        enum CodingKeys: String, CodingKey {
            case address = "Address"
            case id = "Id"
            case name = "Name"
        }
    }

    static func decodeReply(from data: Data) -> DiscoveredServer? {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              !reply.id.isEmpty,
              !reply.address.isEmpty,
              let url = URL(string: reply.address)
        else { return nil }
        let name = reply.name.isEmpty ? "Jellyfin" : reply.name
        return DiscoveredServer(id: reply.id, name: name, address: url)
    }

    func discover() -> AsyncStream<DiscoveredServer> {
        // Implemented in Task 2.
        AsyncStream { $0.finish() }
    }
}
