import Testing
import Foundation
@testable import Sodalite

@MainActor
struct JellyfinServerDiscoveryTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func validReply_decodesAllFields() {
        let server = JellyfinServerDiscovery.decodeReply(
            from: data(#"{"Address":"http://192.168.1.10:8096","Id":"abc123","Name":"Wohnzimmer"}"#)
        )
        #expect(server?.id == "abc123")
        #expect(server?.name == "Wohnzimmer")
        #expect(server?.address.absoluteString == "http://192.168.1.10:8096")
    }

    @Test func emptyName_fallsBackToJellyfin() {
        let server = JellyfinServerDiscovery.decodeReply(
            from: data(#"{"Address":"http://192.168.1.10:8096","Id":"abc123","Name":""}"#)
        )
        #expect(server?.name == "Jellyfin")
    }

    @Test func missingID_returnsNil() {
        #expect(JellyfinServerDiscovery.decodeReply(
            from: data(#"{"Address":"http://192.168.1.10:8096","Name":"X"}"#)
        ) == nil)
    }

    @Test func emptyAddress_returnsNil() {
        #expect(JellyfinServerDiscovery.decodeReply(
            from: data(#"{"Address":"","Id":"abc123","Name":"X"}"#)
        ) == nil)
    }

    @Test func malformedJSON_returnsNil() {
        #expect(JellyfinServerDiscovery.decodeReply(from: data("not json")) == nil)
    }
}
