import Foundation
import Testing
@testable import Sodalite

/// Audit 2026-09-25 NETWORK-3 / NETWORK-4. URLSession replayed `X-Emby-Token` and Seerr's cookie to
/// whatever host a redirect named, https to http included, while it dropped `Authorization` even on
/// a same-host http to https upgrade.
@Suite("Which credentials a redirect may carry")
struct RedirectPolicyTests {

    private func request(_ url: String, credentials: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if credentials {
            request.setValue("MediaBrowser Token=\"tok\"", forHTTPHeaderField: "Authorization")
            request.setValue("connect.sid=cookie", forHTTPHeaderField: "Cookie")
            request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        }
        return request
    }

    @Test("another host gets no credentials, and the other headers survive")
    func crossHostStrips() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("https://auth.example.com/login", credentials: true),
            from: request("https://seerr.example.com/api/v1/auth/me", credentials: true)))
        for name in RedirectPolicy.credentialHeaders {
            #expect(followed.value(forHTTPHeaderField: name) == nil)
        }
        #expect(followed.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("a port change within one scheme is another origin")
    func portChangeStrips() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("http://10.0.0.2:8097/x", credentials: true),
            from: request("http://10.0.0.2:8096/x", credentials: true)))
        #expect(followed.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    }

    @Test("https to http is refused outright")
    func downgradeRefused() {
        #expect(RedirectPolicy.redirect(
            request("http://jf.example.com/x", credentials: true),
            from: request("https://jf.example.com/x", credentials: true)) == nil)
    }

    @Test("a same-host upgrade to https keeps the login, even where URLSession dropped it")
    func upgradeKeepsCredentials() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("https://jf.example.com/Users/AuthenticateByName", credentials: false),
            from: request("http://jf.example.com/Users/AuthenticateByName", credentials: true)))
        #expect(followed.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"tok\"")
        #expect(followed.value(forHTTPHeaderField: "X-Emby-Token") == "tok")
    }

    @Test("the same origin keeps what it had")
    func sameOriginKeeps() throws {
        let followed = try #require(RedirectPolicy.redirect(
            request("https://jf.example.com/web/index.html", credentials: true),
            from: request("https://jf.example.com/web", credentials: true)))
        #expect(followed.value(forHTTPHeaderField: "Cookie") == "connect.sid=cookie")
    }
}
