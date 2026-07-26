import Testing
import Foundation
@testable import Sodalite

/// `sodalite://item/{id}` (Top Shelf displayAction) opens the detail sheet;
/// `sodalite://play/{id}` (playAction, the Play button on the remote) opens it and starts.
@MainActor
struct DeepLinkRouteTests {

    @Test("an item link opens detail without playing")
    func itemLink() {
        let route = DeepLinkRoute.parse(URL(string: "sodalite://item/abc123")!)
        #expect(route == DeepLinkRoute(itemID: "abc123", autoPlay: false))
    }

    @Test("a play link asks for playback")
    func playLink() {
        let route = DeepLinkRoute.parse(URL(string: "sodalite://play/abc123")!)
        #expect(route == DeepLinkRoute(itemID: "abc123", autoPlay: true))
    }

    @Test("a foreign scheme is rejected")
    func foreignScheme() {
        #expect(DeepLinkRoute.parse(URL(string: "jellyfin://item/abc123")!) == nil)
    }

    @Test("an unknown host is rejected")
    func unknownHost() {
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://search/abc123")!) == nil)
    }

    @Test("a missing id is rejected")
    func missingID() {
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://play/")!) == nil)
        #expect(DeepLinkRoute.parse(URL(string: "sodalite://item")!) == nil)
    }

    @Test("trailing path components are ignored")
    func extraComponents() {
        let route = DeepLinkRoute.parse(URL(string: "sodalite://play/abc123/extra")!)
        #expect(route == DeepLinkRoute(itemID: "abc123", autoPlay: true))
    }
}
