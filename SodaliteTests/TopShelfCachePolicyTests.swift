import Testing
@testable import Sodalite

/// The shelf keeps its last good content when a fetch fails. The only staleness rule is identity:
/// a cache may be shown when it belongs to the session currently in the keychain. No TTL.
@MainActor
struct TopShelfCachePolicyTests {

    @Test("same server and user may use the cache")
    func identityMatches() {
        #expect(TopShelfCachePolicy.matches(cachedServerURL: "https://jf.example.com",
                                            cachedUserID: "u1",
                                            sessionServerURL: "https://jf.example.com",
                                            sessionUserID: "u1"))
    }

    @Test("a trailing slash is not a different server")
    func trailingSlashIgnored() {
        #expect(TopShelfCachePolicy.matches(cachedServerURL: "https://jf.example.com/",
                                            cachedUserID: "u1",
                                            sessionServerURL: "https://jf.example.com",
                                            sessionUserID: "u1"))
    }

    @Test("another profile may not use the cache")
    func userMismatch() {
        #expect(!TopShelfCachePolicy.matches(cachedServerURL: "https://jf.example.com",
                                             cachedUserID: "u1",
                                             sessionServerURL: "https://jf.example.com",
                                             sessionUserID: "u2"))
    }

    @Test("another server may not use the cache")
    func serverMismatch() {
        #expect(!TopShelfCachePolicy.matches(cachedServerURL: "https://jf.example.com",
                                             cachedUserID: "u1",
                                             sessionServerURL: "https://other.example.com",
                                             sessionUserID: "u1"))
    }

    @Test("a successful fetch is written")
    func writesOnSuccess() {
        #expect(TopShelfCachePolicy.shouldWrite(resumeSucceeded: true, nextUpSucceeded: true))
    }

    @Test("one surviving fetch still writes")
    func writesOnPartialSuccess() {
        #expect(TopShelfCachePolicy.shouldWrite(resumeSucceeded: true, nextUpSucceeded: false))
        #expect(TopShelfCachePolicy.shouldWrite(resumeSucceeded: false, nextUpSucceeded: true))
    }

    @Test("a total failure never overwrites a good cache")
    func neverOverwritesWithNothing() {
        #expect(!TopShelfCachePolicy.shouldWrite(resumeSucceeded: false, nextUpSucceeded: false))
    }
}
