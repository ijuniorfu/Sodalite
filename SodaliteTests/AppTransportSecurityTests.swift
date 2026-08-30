import Foundation
import Testing

/// Pins the app's ATS policy, which is one key wide and breaks silently.
///
/// `NSAllowsArbitraryLoads` is ignored the moment any of `NSAllowsLocalNetworking`,
/// `NSAllowsArbitraryLoadsInWebContent` or `NSAllowsArbitraryLoadsInMedia` sits beside it (iOS and
/// tvOS 10 and later), and the plain default takes over: cleartext to the local network only. The
/// two keys together read as "everything, and the LAN especially", which is why the pair survived
/// in both Info.plists until a reporter with a self-hosted Jellyfin on a public address over plain
/// http could not get past setup. Nothing in a build log says the key was dropped, so the plist
/// itself is the only place this can be caught.
///
/// `Bundle.main` here is the test host, which is the shipping app.
@Suite("App Transport Security")
struct AppTransportSecurityTests {

    /// Keys whose mere presence disables `NSAllowsArbitraryLoads`.
    private static let neutralizingKeys = [
        "NSAllowsLocalNetworking",
        "NSAllowsArbitraryLoadsInWebContent",
        "NSAllowsArbitraryLoadsInMedia",
    ]

    @Test func arbitraryLoadsIsAllowedAndNothingNeutralizesIt() throws {
        let ats = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any],
            "the app declares no ATS policy at all, so cleartext http is off everywhere"
        )

        #expect(ats["NSAllowsArbitraryLoads"] as? Bool == true)

        for key in Self.neutralizingKeys {
            #expect(
                ats[key] == nil,
                "\(key) is present, which makes the OS ignore NSAllowsArbitraryLoads and cuts cleartext http to anything outside the local network"
            )
        }
    }

    /// The behaviour the key exists for: a cleartext request to a public address has to reach the
    /// transport instead of being refused by the policy. Uses TEST-NET-3 (RFC 5737), which is
    /// reserved for documentation and routed nowhere, so the request goes out and dies on its own.
    /// Any transport verdict passes; only `-1022` fails, and that one needs no network to be
    /// observed, since ATS refuses before a packet is sent.
    @Test func cleartextToAPublicAddressIsNotRefusedByPolicy() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)

        do {
            _ = try await session.data(from: URL(string: "http://203.0.113.1:1000/")!)
        } catch {
            let failure = error as NSError
            #expect(
                !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorAppTransportSecurityRequiresSecureConnection),
                "ATS refused a cleartext request to a public address, which is what locks a self-hosted http server out of setup"
            )
        }
    }
}
