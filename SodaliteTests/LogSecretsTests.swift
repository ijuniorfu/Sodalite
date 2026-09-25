import Foundation
import Testing
@testable import Sodalite

/// Audit 2026-09-25 DIAG-2: an Xtream M3U short-form upstream carries the IPTV password as a bare
/// path segment, which no layout rule can recognise, and Sodalite used to log the URL whole.
@Suite("Credentials named to the log redactors")
struct LogSecretsTests {

    private let upstream = URL(string: "http://iptv.example:8080/bob/SECRETxtream42/1234.m3u8")!

    @Test("an upstream is logged as host plus last component")
    func upstreamDescription() {
        #expect(LogSecrets.upstreamDescription(upstream) == "http://iptv.example:8080/.../1234.m3u8")
        #expect(!LogSecrets.upstreamDescription(upstream).contains("bob"))
    }

    @Test("the short form's middle segment is the secret, other depths are left to the layout rules")
    func shortFormSecret() {
        #expect(LogSecrets.xtreamShortFormSecret(in: upstream) == "SECRETxtream42")
        #expect(LogSecrets.xtreamShortFormSecret(in: URL(string: "http://h/live/bob/pw123456/1.ts")!) == nil)
        #expect(LogSecrets.xtreamShortFormSecret(in: URL(string: "http://h/a/1234/b.m3u8")!) == nil)
    }

    @Test("once taken into custody, the password is gone from every later line")
    func registeredUpstreamIsRedacted() {
        LogSecrets.registerUpstreamCredentials(in: upstream)
        let line = LogRedaction.redact("[HLSIngest] terminal: GET \(upstream.absoluteString) failed")
        #expect(!line.contains("SECRETxtream42"))
        #expect(line.contains("iptv.example:8080/bob/"))
    }

    @Test("a Seerr cookie is registered as sent and as decoded")
    func cookieValues() {
        #expect(LogSecrets.cookieValues("connect.sid=s%3Aabc.def; Path=/") == ["s%3Aabc.def", "s:abc.def"])
        #expect(LogSecrets.cookieValues("connect.sid=") == [])
    }
}
