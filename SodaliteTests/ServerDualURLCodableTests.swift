import Foundation
import Testing
@testable import Sodalite

@Suite("Dual-URL model migration and round-trips")
struct ServerDualURLCodableTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: JellyfinServer

    @Test("legacy blob with internal IP decodes into the internal slot")
    func legacyInternalMigration() throws {
        let json = #"{"id":"s1","name":"NAS","url":"http://192.168.1.10:8096","version":"10.10"}"#
        let server = try JSONDecoder().decode(JellyfinServer.self, from: Data(json.utf8))
        #expect(server.internalURL == url("http://192.168.1.10:8096"))
        #expect(server.externalURL == nil)
        #expect(server.url == url("http://192.168.1.10:8096"))
    }

    @Test("legacy blob with public domain decodes into the external slot")
    func legacyExternalMigration() throws {
        let json = #"{"id":"s1","name":"NAS","url":"https://jf.example.com"}"#
        let server = try JSONDecoder().decode(JellyfinServer.self, from: Data(json.utf8))
        #expect(server.internalURL == nil)
        #expect(server.externalURL == url("https://jf.example.com"))
        #expect(server.url == url("https://jf.example.com"))
    }

    @Test("encode emits both slots plus the legacy url key")
    func encodeKeepsLegacyKey() throws {
        let server = JellyfinServer(
            id: "s1", name: "NAS",
            internalURL: url("http://192.168.1.10:8096"),
            externalURL: url("https://jf.example.com"),
            version: nil
        )
        let data = try JSONEncoder().encode(server)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["url"] as? String == "http://192.168.1.10:8096")
        #expect(object["internalURL"] as? String == "http://192.168.1.10:8096")
        #expect(object["externalURL"] as? String == "https://jf.example.com")
    }

    @Test("dual-slot round-trip")
    func roundTrip() throws {
        let server = JellyfinServer(
            id: "s1", name: "NAS",
            internalURL: url("http://192.168.1.10:8096"),
            externalURL: url("https://jf.example.com"),
            version: "10.10"
        )
        let decoded = try JSONDecoder().decode(JellyfinServer.self, from: JSONEncoder().encode(server))
        #expect(decoded == server)
    }

    @Test("legacy convenience init classifies")
    func legacyInitClassifies() {
        let internalServer = JellyfinServer(id: "a", name: "A", url: url("http://10.0.0.2:8096"))
        #expect(internalServer.internalURL != nil && internalServer.externalURL == nil)
        let externalServer = JellyfinServer(id: "b", name: "B", url: url("https://jf.example.com"))
        #expect(externalServer.internalURL == nil && externalServer.externalURL != nil)
    }

    @Test("url(for:) and preferredURL")
    func routeAccessors() {
        let dual = JellyfinServer(
            id: "s1", name: "NAS",
            internalURL: url("http://10.0.0.2:8096"),
            externalURL: url("https://jf.example.com"),
            version: nil
        )
        #expect(dual.url(for: .internal) == url("http://10.0.0.2:8096"))
        #expect(dual.url(for: .external) == url("https://jf.example.com"))
        #expect(dual.preferredURL(lastKnown: .external) == url("https://jf.example.com"))
        #expect(dual.preferredURL(lastKnown: nil) == url("http://10.0.0.2:8096"))
        let internalOnly = JellyfinServer(id: "s2", name: "N", url: url("http://10.0.0.2:8096"))
        #expect(internalOnly.preferredURL(lastKnown: .external) == url("http://10.0.0.2:8096"))
    }

    // MARK: SeerrServer

    @Test("SeerrServer legacy migration and round-trip")
    func seerrServer() throws {
        let legacy = #"{"id":"se1","url":"https://seerr.example.com"}"#
        let migrated = try JSONDecoder().decode(SeerrServer.self, from: Data(legacy.utf8))
        #expect(migrated.internalURL == nil)
        #expect(migrated.externalURL == url("https://seerr.example.com"))

        let dual = SeerrServer(
            id: "se1",
            internalURL: url("http://192.168.1.4:5055"),
            externalURL: url("https://seerr.example.com")
        )
        let decoded = try JSONDecoder().decode(SeerrServer.self, from: JSONEncoder().encode(dual))
        #expect(decoded == dual)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(dual)) as? [String: Any])
        #expect(object["url"] as? String == "http://192.168.1.4:5055")
    }
}
