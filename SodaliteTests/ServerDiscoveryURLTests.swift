import Testing
import Foundation
@testable import Sodalite

/// Characterizes ServerDiscoveryService.buildCandidateURLs, the branchiest pure function gating connectivity.
@MainActor
struct ServerDiscoveryURLTests {
    private func candidates(_ input: String) -> [String] {
        ServerDiscoveryService().buildCandidateURLs(from: input).map(\.absoluteString)
    }

    @Test func explicitHTTPSNoPortNoPath_addsDefaultPort() {
        #expect(candidates("https://jelly.example.com") == [
            "https://jelly.example.com",
            "https://jelly.example.com:8920",
        ])
    }

    @Test func explicitHTTPNoPortNoPath_addsDefaultPort() {
        #expect(candidates("http://jelly.example.com") == [
            "http://jelly.example.com",
            "http://jelly.example.com:8096",
        ])
    }

    @Test func explicitSchemeWithBasePath_doesNotAppendPort() {
        // A base path means reverse proxy; default ports must not glue onto it.
        #expect(candidates("https://jelly.example.com/jellyfin") == [
            "https://jelly.example.com/jellyfin",
        ])
    }

    @Test func explicitSchemeWithPort_isLeftAlone() {
        #expect(candidates("https://jelly.example.com:9999") == [
            "https://jelly.example.com:9999",
        ])
    }

    @Test func trailingSlashAndWhitespace_areTrimmed() {
        #expect(candidates("  https://jelly.example.com/  ") == [
            "https://jelly.example.com",
            "https://jelly.example.com:8920",
        ])
    }

    @Test func ipWithoutPort_ordersDefaultPortsThenStandard() {
        #expect(candidates("192.168.1.50") == [
            "https://192.168.1.50:8920",
            "http://192.168.1.50:8096",
            "https://192.168.1.50",
            "http://192.168.1.50",
        ])
    }

    @Test func ipWithPort_doesNotDoublePort() {
        #expect(candidates("192.168.1.50:8096") == [
            "https://192.168.1.50:8096",
            "http://192.168.1.50:8096",
        ])
    }

    @Test func hostnameNoPortNoPath_standardThenDefaultPorts() {
        #expect(candidates("jelly.example.com") == [
            "https://jelly.example.com",
            "http://jelly.example.com",
            "https://jelly.example.com:8920",
            "http://jelly.example.com:8096",
        ])
    }

    @Test func hostnameWithPath_skipsPortVariants() {
        #expect(candidates("jelly.example.com/jellyfin") == [
            "https://jelly.example.com/jellyfin",
            "http://jelly.example.com/jellyfin",
        ])
    }

    @Test func emptyInput_yieldsNoHostedCandidate() {
        // Degenerate input must never surface a candidate with a real (non-empty) host.
        #expect(ServerDiscoveryService().buildCandidateURLs(from: "   ").allSatisfy { ($0.host() ?? "").isEmpty })
    }

    // MARK: Redirect adoption (audit NETWORK-4)

    private func upgraded(_ candidate: String, _ final: String?) -> String {
        ServerDiscoveryService.upgradedBaseURL(
            candidate: URL(string: candidate)!,
            finalURL: final.flatMap(URL.init(string:)),
            endpointPath: "/System/Info/Public"
        ).absoluteString
    }

    @Test func httpToHTTPSUpgradeOnSameHost_isAdopted() {
        #expect(upgraded("http://jf.example.com", "https://jf.example.com/System/Info/Public")
            == "https://jf.example.com")
        #expect(upgraded("http://jf.example.com/jellyfin", "https://JF.example.com:8443/jellyfin/System/Info/Public")
            == "https://JF.example.com:8443/jellyfin")
    }

    @Test func anyOtherRedirect_keepsTheTypedAddress() {
        #expect(upgraded("http://jf.example.com", nil) == "http://jf.example.com")
        #expect(upgraded("http://jf.example.com", "https://other.example.com/System/Info/Public")
            == "http://jf.example.com")
        #expect(upgraded("https://jf.example.com", "http://jf.example.com/System/Info/Public")
            == "https://jf.example.com")
        #expect(upgraded("http://jf.example.com", "https://jf.example.com/login?next=/System/Info/Public")
            == "http://jf.example.com")
    }
}
