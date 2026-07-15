import Foundation
import Testing
@testable import Sodalite

@Suite("Route resolver preference matrix")
struct ServerRouteResolverTests {
    private let internalURL = URL(string: "http://10.0.0.2:8096")!
    private let externalURL = URL(string: "https://jf.example.com")!

    private func probe(reachable: Set<URL>) -> @Sendable (URL) async -> Bool {
        { url in reachable.contains(url) }
    }

    @Test("single internal slot returns without probing")
    func internalOnly() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: nil, lastKnown: nil,
            probe: { _ in Issue.record("must not probe"); return false }
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: internalURL, route: .internal))
    }

    @Test("single external slot returns without probing")
    func externalOnly() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: nil, externalURL: externalURL, lastKnown: nil,
            probe: { _ in Issue.record("must not probe"); return false }
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: externalURL, route: .external))
    }

    @Test("both reachable prefers internal")
    func bothReachable() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: externalURL, lastKnown: .external,
            probe: probe(reachable: [internalURL, externalURL])
        )
        #expect(resolved?.route == .internal)
    }

    @Test("internal dead falls to external")
    func internalDead() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: externalURL, lastKnown: .internal,
            probe: probe(reachable: [externalURL])
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: externalURL, route: .external))
    }

    @Test("both dead falls back to last-known route")
    func bothDeadLastKnown() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: externalURL, lastKnown: .external,
            probe: probe(reachable: [])
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: externalURL, route: .external))
    }

    @Test("both dead without last-known defaults to internal")
    func bothDeadDefault() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: internalURL, externalURL: externalURL, lastKnown: nil,
            probe: probe(reachable: [])
        )
        #expect(resolved == ServerRouteResolver.Resolved(url: internalURL, route: .internal))
    }

    @Test("no slots returns nil")
    func noSlots() async {
        let resolved = await ServerRouteResolver.resolve(
            internalURL: nil, externalURL: nil, lastKnown: nil, probe: { _ in true }
        )
        #expect(resolved == nil)
    }

    @Test("route store round-trip")
    func routeStore() {
        let suite = "route-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerRouteStore(defaults: defaults)
        #expect(store.lastRoute(serverID: "s1") == nil)
        store.setLastRoute(.external, serverID: "s1")
        #expect(store.lastRoute(serverID: "s1") == .external)
        store.setLastRoute(.internal, serverID: "s1")
        #expect(store.lastRoute(serverID: "s1") == .internal)
    }
}
