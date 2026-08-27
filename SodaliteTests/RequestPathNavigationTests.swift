import Testing
import Foundation
@testable import Sodalite

/// Second layer under `DeepLinkRoute`'s id check: every endpoint path in this app is a literal with
/// ids interpolated into it, so a `.` or `..` segment can only have arrived inside one of those ids.
/// It retargets the request while the auth header rides along unchanged, which is why the funnel
/// refuses to send it at all rather than each endpoint having to remember.
struct RequestPathNavigationTests {

    @Test("a plain endpoint path is sent")
    func plainPath() {
        #expect(HTTPClient.navigatesUpward(URL(string: "https://jf.example.com/Users/UID/Items/abc")!) == false)
    }

    @Test("a traversal is refused")
    func traversal() {
        #expect(HTTPClient.navigatesUpward(URL(string: "https://jf.example.com/Users/UID/Items/../../System/Info")!))
    }

    @Test("a single dot segment is refused too")
    func singleDot() {
        #expect(HTTPClient.navigatesUpward(URL(string: "https://jf.example.com/Users/./Items/abc")!))
    }

    /// The shapes a reverse proxy or a base path produces every day. A guard that fired on these
    /// would take the app off the air, so they are the ones worth pinning.
    @Test("legitimate shapes still pass")
    func legitimateShapes() {
        let fine = [
            "https://jf.example.com",
            "https://jf.example.com/",
            "https://jf.example.com/jellyfin/Users/UID/Items",
            "https://jf.example.com/Users/UID/Items/",
            "https://jf.example.com/Users/UID//Items/abc",
            "https://jf.example.com/Users/UID/Items/abc?fields=Overview",
            "https://jf.example.com/Items/x/RemoteSearch/Subtitles/prov%2Fsub.id",
        ]
        for raw in fine {
            #expect(HTTPClient.navigatesUpward(URL(string: raw)!) == false, "\(raw) should be sendable")
        }
    }

    /// The endpoint path the request is actually built from, end to end.
    ///
    /// Asserts `.invalidURL` specifically, not just "it threw": without the guard this request goes
    /// out and comes back as `.networkError`, so a plain throws-check would pass on the very
    /// behaviour it is here to forbid.
    @Test("the funnel refuses a retargeted request before it goes out")
    func funnelRefuses() async {
        let client = HTTPClient()
        var caught: APIError?
        do {
            try await client.request(
                baseURL: URL(string: "https://jf.example.com")!,
                endpoint: JellyfinEndpoint.itemDetail(userID: "UID", itemID: "../../System/Info"),
                headers: [:]
            )
        } catch let error as APIError {
            caught = error
        } catch {
            caught = nil
        }
        guard case .invalidURL = caught else {
            Issue.record("expected .invalidURL, got \(String(describing: caught))")
            return
        }
    }

    /// The same request with a real id has to reach the transport, else the test above would also
    /// pass with a funnel that refuses everything.
    @Test("a plain id gets past the funnel and fails on the network instead")
    func plainIDReachesTransport() async {
        let client = HTTPClient()
        var caught: APIError?
        do {
            try await client.request(
                baseURL: URL(string: "https://sodalite.invalid")!,
                endpoint: JellyfinEndpoint.itemDetail(userID: "UID", itemID: "0f9b1c2d3e4f5061728394a5b6c7d8e9"),
                headers: [:]
            )
        } catch let error as APIError {
            caught = error
        } catch {
            caught = nil
        }
        if case .invalidURL = caught {
            Issue.record("the funnel rejected a legitimate path")
        }
    }
}
