import Foundation

/// Picks the live URL for a dual-slot server. Both slots are probed in
/// parallel; internal wins whenever it answers, external is the fallback,
/// and when neither answers the last-known route keeps the session on
/// whatever worked before (existing error paths then surface the outage).
enum ServerRouteResolver {
    struct Resolved: Equatable, Sendable {
        let url: URL
        let route: ServerRoute
    }

    static func resolve(
        internalURL: URL?,
        externalURL: URL?,
        lastKnown: ServerRoute?,
        probe: @escaping @Sendable (URL) async -> Bool
    ) async -> Resolved? {
        switch (internalURL, externalURL) {
        case (nil, nil):
            return nil
        case (let internalURL?, nil):
            return Resolved(url: internalURL, route: .internal)
        case (nil, let externalURL?):
            return Resolved(url: externalURL, route: .external)
        case (let internalURL?, let externalURL?):
            async let externalReachable = probe(externalURL)
            if await probe(internalURL) {
                return Resolved(url: internalURL, route: .internal)
            }
            if await externalReachable {
                return Resolved(url: externalURL, route: .external)
            }
            let fallback = lastKnown ?? .internal
            return Resolved(
                url: fallback == .internal ? internalURL : externalURL,
                route: fallback
            )
        }
    }
}

/// Reachability probes against unauthenticated status endpoints. Any HTTP
/// response (including 401/5xx) proves the host answers on this route; only
/// transport errors count as unreachable. Per-request ephemeral session,
/// invalidated after use (long-lived sessions retain response data, see the
/// URLSession task-pool leak note in project memory).
enum ServerProbe {
    static let timeout: TimeInterval = 2

    static func jellyfin(_ base: URL) async -> Bool {
        await responds(at: base.appending(path: "System/Info/Public"))
    }

    static func seerr(_ base: URL) async -> Bool {
        await responds(at: base.appending(path: "api/v1/status"))
    }

    private static func responds(at url: URL) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: url)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}

/// Last route that worked per server id; seeds the synchronous client setup
/// on launch and the both-probes-dead fallback.
struct ServerRouteStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastRoute(serverID: String) -> ServerRoute? {
        defaults.string(forKey: key(serverID)).flatMap(ServerRoute.init(rawValue:))
    }

    func setLastRoute(_ route: ServerRoute, serverID: String) {
        defaults.set(route.rawValue, forKey: key(serverID))
    }

    private func key(_ serverID: String) -> String { "serverRoute.\(serverID)" }
}
