import Foundation
import Testing
@testable import Sodalite

/// The diagnostic log is meant to be handed to someone else, so a credential that survives into it is
/// published the moment a reporter screenshots it. These pin the shapes that actually occur in Sodalite's
/// own lines and in AetherEngine's, not a generic notion of "looks secret".
@Suite("Diagnostic log credential stripping")
struct LogRedactionTests {

    private let token = "9f2c1ab34de5470fa1b6c8d90e7f2a11"

    @Test("the Jellyfin stream URL loses its api_key and keeps everything else")
    func streamURLQuery() {
        let line = LogRedaction.redact(
            "[AetherEngine] load url=https://media.example.org/Videos/abc123/stream.mkv" +
            "?api_key=\(token)&Static=true&MediaSourceId=abc123 source-format=mkv"
        )
        #expect(!line.contains(token))
        #expect(line.contains("api_key=<redacted>"))
        // The parts a playback bug is actually diagnosed from must survive.
        #expect(line.contains("media.example.org/Videos/abc123/stream.mkv"))
        #expect(line.contains("Static=true"))
        #expect(line.contains("MediaSourceId=abc123"))
        #expect(line.hasSuffix("source-format=mkv"))
    }

    /// JellyfinImageService threads the token through BOTH spellings for server-version coverage, so
    /// stripping only the classic one would still ship the credential.
    @Test("both api_key and ApiKey spellings are stripped")
    func bothImageTokenSpellings() {
        let line = LogRedaction.redact(
            "[Image] fetch failed https://s/Items/1/Images/Primary?api_key=\(token)&ApiKey=\(token): timeout"
        )
        #expect(!line.contains(token))
        #expect(line.contains("api_key=<redacted>"))
        #expect(line.contains("ApiKey=<redacted>"))
        #expect(line.hasSuffix(": timeout"))
    }

    @Test("the MediaBrowser header form is stripped inside its quotes")
    func headerForm() {
        let line = LogRedaction.redact(#"Authorization: MediaBrowser Client="Sodalite", Token="\#(token)", Device="Apple TV""#)
        #expect(!line.contains(token))
        #expect(line.contains(#"Token="<redacted>""#))
        #expect(line.contains(#"Client="Sodalite""#))
        #expect(line.contains(#"Device="Apple TV""#))
    }

    @Test("the Seerr session cookie is stripped up to the attribute separator")
    func cookieForm() {
        let line = LogRedaction.redact("[Seerr] connect.sid=s%3Aabc.def+ghi; Path=/; HttpOnly")
        #expect(!line.contains("s%3Aabc.def"))
        #expect(line.contains("connect.sid=<redacted>"))
        #expect(line.hasSuffix("; Path=/; HttpOnly"))
    }

    @Test("X-Emby-Token and X-MediaBrowser-Token are stripped once, not twice")
    func headerNameVariants() {
        let line = LogRedaction.redact("X-Emby-Token=\(token) X-MediaBrowser-Token=\(token)")
        #expect(line == "X-Emby-Token=<redacted> X-MediaBrowser-Token=<redacted>")
    }

    /// A header separator spaces its value out; an `=` never does. Both have to work, and the second
    /// rule is what keeps "api_key= (missing)" from reading as a credential.
    @Test("the colon-separated header form is stripped")
    func colonSeparatedHeader() {
        let line = LogRedaction.redact("[http] X-Emby-Token: \(token) sent")
        #expect(!line.contains(token))
        #expect(line == "[http] X-Emby-Token: <redacted> sent")
    }

    /// The broad `token` key must not fire mid-identifier, or ordinary diagnostics start reading as
    /// redactions and the log loses the counters it exists for.
    @Test("a token substring inside another identifier is left alone")
    func doesNotFireMidIdentifier() {
        for line in [
            "[session] hasToken=true refreshTokenAt=120s",
            "[SWDiag] enq=48 layerDrop=0 delay=0.02 cushion=1.8",
            "[LiveDirect] eligible: route=hls tuner=file",
        ] {
            #expect(LogRedaction.redact(line) == line)
        }
    }

    @Test("an empty value and a bare mention are left alone")
    func nothingToStrip() {
        #expect(LogRedaction.redact("[auth] api_key= (missing)") == "[auth] api_key= (missing)")
        #expect(LogRedaction.redact("no token was supplied") == "no token was supplied")
    }

    @Test("several credentials in one line are all stripped")
    func multiplePerLine() {
        let line = LogRedaction.redact("a=1&api_key=\(token)&b=2&token=\(token)&c=3")
        #expect(!line.contains(token))
        #expect(line == "a=1&api_key=<redacted>&b=2&token=<redacted>&c=3")
    }

    /// The loopback URLs the engine serves on carry no credential; they are the most common URL in the
    /// log and must come through untouched.
    @Test("a loopback serving URL is untouched")
    func loopbackURL() {
        let line = "[HLSVideoEngine] serving on http://127.0.0.1:52341/master.m3u8 (dvModeAvailable=true)"
        #expect(LogRedaction.redact(line) == line)
    }

    @Test("redaction runs on the way into the buffer, not only in the view")
    @MainActor
    func tapRedactsOnIngest() async {
        LogTap.shared.clear()
        LogTap.shared.note("[test] url=https://s/x?api_key=\(token)")
        // note(_:) hops to the main queue; let that drain.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(LogTap.shared.lines.contains { $0.contains("api_key=<redacted>") })
        #expect(!LogTap.shared.lines.contains { $0.contains(token) })
        LogTap.shared.clear()
    }
}
