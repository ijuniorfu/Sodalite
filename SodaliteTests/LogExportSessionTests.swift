import Testing
import Foundation
@testable import Sodalite

/// Sodalite#148, classicjazz: "some way to export or copy the Diagnostic Log off the Apple TV without
/// requiring multiple screenshots and without Sodalite transferring log files to a remote server".
///
/// The socket layer is not testable without a network, so everything that decides WHAT goes over it
/// lives in `LogExportSession` and is pinned here: which paths answer, which do not, what the served
/// bytes say, and when the session stops answering at all. The page is served over plain HTTP on a
/// LAN address, which is not a secure context, so the tests also pin the two things that follow from
/// that: the copy path cannot depend on `navigator.clipboard`, and nothing on the page may be fetched
/// from anywhere but this device.
struct LogExportSessionTests {

    private static let environment = LogExportSession.Environment(
        appVersion: "1.0",
        build: "42",
        systemName: "tvOS",
        systemVersion: "26.6",
        hardware: "AppleTV14,1"
    )

    private static let capture = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(
        lines: [String] = ["[session] first line", "[player] second line"],
        capturedAt: Date = capture,
        lifetime: TimeInterval = 300
    ) -> LogExportSession {
        LogExportSession(
            lines: lines,
            environment: environment,
            capturedAt: capturedAt,
            lifetime: lifetime
        )
    }

    private static func get(_ path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: 192.168.1.20:52341\r\n\r\n"
    }

    private static func body(_ response: LogExportResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    // MARK: - The token

    /// The only thing between the log and everyone else on the network. A predictable token would make
    /// the export readable by anyone who guesses the port, which on an ephemeral range is a short list.
    @Test("each session carries its own unguessable token")
    func tokenIsRandomAndHex() {
        let tokens = (0 ..< 32).map { _ in Self.session().token }

        for token in tokens {
            #expect(token.count == 32, "a 128 bit token in hex is 32 characters, got \(token.count)")
            #expect(
                token.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
                "the token goes in a URL that is read off a screen, so it stays lowercase hex: \(token)"
            )
        }

        #expect(Set(tokens).count == tokens.count, "two sessions drew the same token")
    }

    // MARK: - Routing

    @Test("the token path serves the page")
    func tokenPathServesPage() {
        let session = Self.session()
        let response = session.response(to: Self.get("/\(session.token)"), now: Self.capture)

        #expect(response.status == 200)
        #expect(response.contentType.hasPrefix("text/html"))
        #expect(Self.body(response).contains("[session] first line"))
    }

    /// A browser that has been to the page once will append its own cache buster on a reload, and a
    /// QR scanner may add a referrer parameter. Neither is a different resource.
    @Test("a query string does not change which resource is asked for")
    func queryStringIsIgnored() {
        let session = Self.session()
        let response = session.response(to: Self.get("/\(session.token)?utm=scan"), now: Self.capture)

        #expect(response.status == 200)
    }

    @Test("the text path serves the document verbatim")
    func textPathServesDocument() {
        let session = Self.session()
        let response = session.response(to: Self.get("/\(session.token)/log.txt"), now: Self.capture)

        #expect(response.status == 200)
        #expect(response.contentType.hasPrefix("text/plain"))
        #expect(Self.body(response) == session.document)
    }

    @Test("everything that is not the token is a 404", arguments: [
        "/",
        "/favicon.ico",
        "/log.txt",
        "/0123456789abcdef0123456789abcdef",
        "/../../etc/passwd",
    ])
    func unknownPathsAreNotFound(path: String) {
        let session = Self.session()
        let response = session.response(to: Self.get(path), now: Self.capture)

        #expect(response.status == 404, "\(path) answered \(response.status)")
        #expect(!Self.body(response).contains("first line"), "\(path) leaked the log")
    }

    /// The token is compared whole. A prefix that happens to match must not open the door, which is
    /// what a `hasPrefix` check on the path would do.
    @Test("a path that merely starts with the token is not the token")
    func tokenPrefixIsNotEnough() {
        let session = Self.session()
        let response = session.response(to: Self.get("/\(session.token)abc"), now: Self.capture)

        #expect(response.status == 404)
    }

    @Test("only GET is answered")
    func onlyGETIsAnswered() {
        let session = Self.session()
        let request = "POST /\(session.token) HTTP/1.1\r\nHost: x\r\n\r\n"

        #expect(session.response(to: request, now: Self.capture).status == 405)
    }

    @Test("a request that is not HTTP gets a 400 and no log")
    func malformedRequestIsRejected() {
        let session = Self.session()
        let response = session.response(to: "\u{16}\u{03}\u{01}garbage", now: Self.capture)

        #expect(response.status == 400)
        #expect(!Self.body(response).contains("first line"))
    }

    // MARK: - Expiry

    /// The listener is closed at the deadline, so this branch only catches a connection already in
    /// flight. It still has to be the one branch that cannot serve the log.
    @Test("an expired session stops serving the log")
    func expiredSessionServesGone() {
        let session = Self.session(lifetime: 300)
        let response = session.response(
            to: Self.get("/\(session.token)"),
            now: Self.capture.addingTimeInterval(301)
        )

        #expect(response.status == 410)
        #expect(!Self.body(response).contains("first line"))
    }

    @Test("a session one second short of its deadline still serves")
    func sessionServesUntilTheDeadline() {
        let session = Self.session(lifetime: 300)
        let response = session.response(
            to: Self.get("/\(session.token)"),
            now: Self.capture.addingTimeInterval(299)
        )

        #expect(response.status == 200)
    }

    // MARK: - What the reporter hands over

    /// Every issue that arrives without a version and an OS costs a round trip to ask for them. The
    /// header is part of the DOCUMENT rather than the page chrome, so it survives both the copy
    /// button and a saved `log.txt`.
    @Test("the document names the build, the system and the hardware it came from")
    func documentCarriesItsProvenance() {
        let document = Self.session().document

        #expect(document.contains("Sodalite 1.0 (42)"))
        #expect(document.contains("tvOS 26.6"))
        #expect(document.contains("AppleTV14,1"))
        #expect(document.contains("2 lines"))
        #expect(document.contains("2027-01-15"), "the capture time is stamped in UTC: \(document)")
    }

    @Test("the document ends with the lines in the order they were logged")
    func documentKeepsLineOrder() {
        let lines = (0 ..< 20).map { "line \($0)" }
        let document = Self.session(lines: lines).document

        #expect(document.hasSuffix(lines.joined(separator: "\n")))
    }

    /// The buffer keeps filling while the reporter reads the page on a phone. Serving a moving target
    /// would mean the text they paste is not the text they were looking at.
    @Test("the snapshot is taken once and does not move")
    func snapshotIsFrozen() {
        var lines = ["one"]
        let session = Self.session(lines: lines)
        lines.append("two")

        #expect(!session.document.contains("two"))
    }

    @Test("an empty buffer still produces a document with a header")
    func emptyBufferStillHasHeader() {
        let document = Self.session(lines: []).document

        #expect(document.contains("Sodalite 1.0 (42)"))
        #expect(document.contains("0 lines"))
    }

    // MARK: - The page

    /// A log line is arbitrary text from a server, a file name or an error message. Unescaped it can
    /// close the `pre` and run as markup.
    @Test("log text cannot become markup")
    func pageEscapesLogText() {
        let session = Self.session(lines: ["<script>alert('x')</script>", "a & b </pre>"])
        let page = Self.body(session.response(to: Self.get("/\(session.token)"), now: Self.capture))

        #expect(!page.contains("<script>alert"))
        #expect(page.contains("&lt;script&gt;"))
        #expect(page.contains("a &amp; b &lt;/pre&gt;"))
    }

    /// Served over http:// to a LAN address, so the page is not a secure context: in Safari
    /// `navigator.clipboard` is undefined there, and a copy button wired to it alone is a button that
    /// silently does nothing. The fallback is the whole feature working or not.
    @Test("the copy button has a path that works outside a secure context")
    func copyHasNonSecureContextFallback() {
        let session = Self.session()
        let page = Self.body(session.response(to: Self.get("/\(session.token)"), now: Self.capture))

        #expect(page.contains("execCommand"), "no clipboard fallback for a plain http origin")
    }

    /// No stylesheet, no font, no script from anywhere. The phone that opens this page may have no
    /// route to the internet at all, and a log that needs a CDN to be readable is not a local export.
    @Test("the page fetches nothing from outside this device")
    func pageIsSelfContained() {
        let session = Self.session()
        let page = Self.body(session.response(to: Self.get("/\(session.token)"), now: Self.capture))

        #expect(!page.contains("https://"))
        #expect(!page.contains("http://"))
        #expect(!page.contains("//cdn"))
    }

    @Test("the page links its own plain text copy")
    func pageLinksTheTextDocument() {
        let session = Self.session()
        let page = Self.body(session.response(to: Self.get("/\(session.token)"), now: Self.capture))

        #expect(page.contains("/\(session.token)/log.txt"))
    }

    // MARK: - The wire

    @Test("a response serializes as HTTP/1.1 with a byte count that matches its body")
    func responseSerializesWithMatchingLength() throws {
        let session = Self.session(lines: ["Grüße aus München"])
        let response = session.response(to: Self.get("/\(session.token)/log.txt"), now: Self.capture)
        let wire = String(decoding: response.serialized, as: UTF8.self)

        let head = try #require(wire.range(of: "\r\n\r\n"))
        let headers = String(wire[wire.startIndex ..< head.lowerBound])

        #expect(headers.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(headers.contains("Content-Length: \(response.body.count)"))
        #expect(
            headers.contains("charset=utf-8"),
            "a log carries non-ASCII file names, so the encoding is declared: \(headers)"
        )
        #expect(headers.contains("Cache-Control: no-store"), "an expired link must not be reloadable from cache")
        #expect(headers.contains("Connection: close"))
    }

    /// The document is served as UTF-8 and counted in bytes, not characters. A single umlaut in a file
    /// name is enough to make a character count a truncated response.
    @Test("the length counts bytes, not characters")
    func lengthCountsBytes() {
        let session = Self.session(lines: ["Grüße"])
        let response = session.response(to: Self.get("/\(session.token)/log.txt"), now: Self.capture)

        #expect(response.body.count > Self.body(response).count)
    }
}
