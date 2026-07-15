import Foundation
import Testing
@testable import Sodalite

@Suite("Server URL host classification")
struct ServerURLClassifierTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("private IPv4 ranges are internal", arguments: [
        "http://10.0.0.5:8096",
        "http://172.16.0.1:8096",
        "http://172.31.255.254",
        "http://192.168.1.10:8096",
        "http://169.254.10.10",
        "http://127.0.0.1:8096",
    ])
    func privateIPv4(_ s: String) {
        #expect(ServerURLClassifier.isInternal(url(s)))
    }

    @Test("public IPv4 and CGNAT are external", arguments: [
        "http://8.8.8.8:8096",
        "http://100.64.0.1:8096",
        "http://100.100.50.2",
        "http://172.32.0.1",
        "http://11.0.0.1",
    ])
    func publicIPv4(_ s: String) {
        #expect(!ServerURLClassifier.isInternal(url(s)))
    }

    @Test("internal hostnames", arguments: [
        "http://nas:8096",
        "http://jellyfin.local:8096",
        "http://server.lan",
        "http://media.home",
        "http://media.home.arpa",
        "http://jf.internal",
        "http://Jellyfin.LOCAL:8096",
    ])
    func internalHostnames(_ s: String) {
        #expect(ServerURLClassifier.isInternal(url(s)))
    }

    @Test("public domains are external", arguments: [
        "https://jellyfin.example.com",
        "https://media.mydomain.de:443",
        "https://localdomain.com",
    ])
    func publicDomains(_ s: String) {
        #expect(!ServerURLClassifier.isInternal(url(s)))
    }

    @Test("IPv6 loopback, ULA, link-local are internal", arguments: [
        "http://[::1]:8096",
        "http://[fd12:3456:789a::1]:8096",
        "http://[fc00::1]",
        "http://[fe80::1%25en0]",
    ])
    func internalIPv6(_ s: String) {
        #expect(ServerURLClassifier.isInternal(url(s)))
    }

    @Test("global IPv6 is external")
    func globalIPv6() {
        #expect(!ServerURLClassifier.isInternal(url("http://[2001:db8::1]:8096")))
    }
}
