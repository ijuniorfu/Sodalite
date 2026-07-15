import Foundation
import Observation

@Observable
@MainActor
final class ServerDiscoveryViewModel {
    enum Phase { case scanning, results, empty }

    private(set) var phase: Phase = .scanning
    private(set) var servers: [DiscoveredServer] = []
    var isConnecting = false
    var errorMessage: String?

    let knownServerIDs: Set<String>
    private let discovery: JellyfinServerDiscoveryProtocol
    private let discoveryService: ServerDiscoveryServiceProtocol

    init(
        discovery: JellyfinServerDiscoveryProtocol,
        discoveryService: ServerDiscoveryServiceProtocol,
        knownServerIDs: Set<String>
    ) {
        self.discovery = discovery
        self.discoveryService = discoveryService
        self.knownServerIDs = knownServerIDs
    }

    func scan() async {
        servers = []
        phase = .scanning
        for await server in discovery.discover() where !servers.contains(where: { $0.id == server.id }) {
            servers.append(server)
            phase = .results
        }
        if servers.isEmpty { phase = .empty }
    }

    /// Runs the discovered address through the existing probe so we recover id/name/version and reuse the login flow.
    func selectServer(_ discovered: DiscoveredServer) async -> JellyfinServer? {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let result = await discoveryService.discoverServer(input: discovered.address.absoluteString)
        switch result {
        case .success(let url, let info):
            // Found on the local network: pin to the internal slot regardless of hostname shape.
            return JellyfinServer(id: info.id, name: info.serverName, internalURL: url, externalURL: nil, version: info.version)
        case .failure(let error):
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func isAlreadyAdded(_ server: DiscoveredServer) -> Bool {
        knownServerIDs.contains(server.id)
    }
}
