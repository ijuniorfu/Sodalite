import Foundation

/// Strips credentials out of a diagnostic line before it enters `LogTap`.
///
/// The log exists to be handed to someone else: a screenshot in a GitHub issue, a paste into Discord
/// through the iOS Copy button. Jellyfin puts the access token in the QUERY (`api_key=` on every stream
/// URL, and `ApiKey=` as well from the image service), so an unfiltered log is a live credential the
/// moment a user shares it.
///
/// AetherEngine gained the same redaction in its own `EngineLog` (PR #431), so once that pin lands here
/// the lines arriving through `EngineLog.handler` are already clean. This stays regardless: the lines the
/// host composes itself (`[Image] fetch failed <url>`, `[discovery]`, `[session]`) never pass through the
/// engine. Running twice is harmless, the second pass finds a placeholder rather than a secret.
///
/// Placed on the `LogTap.note(_:)` funnel rather than at each call site on purpose, so a line added
/// tomorrow is covered without anyone remembering this file. Over-redaction is the safe failure here,
/// under-redaction is the leak. The value is replaced whole rather than truncated to a prefix: a prefix
/// still narrows a brute-force and answers no question a playback bug asks. Everything else about the
/// URL (host, path, item id, container, bitrate, subtitle index) survives, which is the part that
/// answers the bug.
nonisolated enum LogRedaction {

    static let placeholder = "<redacted>"

    /// Jellyfin and Seerr credential names plus the generic ones, so a future backend is covered too.
    /// Held as lowercase ASCII bytes and matched longest first, so `x-mediabrowser-token` wins over its
    /// `token` suffix. `token` alone is deliberately broad and only fires on a boundary, so identifiers
    /// such as `hasToken` and `refreshTokenAt` are left alone.
    private static let keys: [[UInt8]] = [
        "x-mediabrowser-token", "x-emby-token", "access_token", "accesstoken", "connect.sid",
        "signature", "password", "api_key", "apikey", "secret", "token",
    ].map { Array($0.utf8) }

    private static let placeholderBytes = Array(placeholder.utf8)

    /// Works on UTF-8 bytes, not Characters, and allocates the output only once something actually
    /// matches. That is not premature: a Character-level pass building a lowercased String per position
    /// cost enough on this hot path to shift request timing in an AetherEngine test, which is how the
    /// first version of this file was caught. Every engine line passes through `note(_:)`, so anything
    /// per-line here is per-line for the whole session.
    static func redact(_ line: String) -> String {
        let bytes = Array(line.utf8)
        var out: [UInt8]?
        var copiedUpTo = 0
        var i = 0

        while i < bytes.count {
            guard let keyLength = matchedKeyLength(in: bytes, at: i),
                  let value = valueRange(in: bytes, after: i + keyLength) else {
                i += 1
                continue
            }
            if out == nil {
                out = []
                out?.reserveCapacity(bytes.count)
            }
            out?.append(contentsOf: bytes[copiedUpTo ..< value.lowerBound])
            out?.append(contentsOf: placeholderBytes)
            copiedUpTo = value.upperBound
            i = value.upperBound
        }

        guard var out else { return line }
        out.append(contentsOf: bytes[copiedUpTo...])
        return String(decoding: out, as: UTF8.self)
    }

    /// Length of the key starting here, or nil. The key must start on a boundary, else `token` would
    /// fire inside `hasToken`. A separator such as the `-` in `X-Emby-Token` or the `_` in `api_key` is
    /// a boundary; an ASCII letter or digit is not.
    private static func matchedKeyLength(in bytes: [UInt8], at index: Int) -> Int? {
        if index > 0, isLetterOrDigit(bytes[index - 1]) { return nil }
        for key in keys where index + key.count <= bytes.count {
            var matched = true
            for offset in 0 ..< key.count where lowercased(bytes[index + offset]) != key[offset] {
                matched = false
                break
            }
            if matched { return key.count }
        }
        return nil
    }

    /// The span holding the secret, given the index just past the key. Covers the query form
    /// (`api_key=abc&next=1`), both header forms (`Token="abc"`, `X-Emby-Token: abc`) and the cookie
    /// form (`connect.sid=abc; Path=/`). Nil when there is no assignment or the value is empty, so
    /// `api_key=` and a bare mention in prose are left alone.
    private static func valueRange(in bytes: [UInt8], after keyEnd: Int) -> Range<Int>? {
        var i = keyEnd
        while i < bytes.count, bytes[i] == UInt8(ascii: " ") { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "=") || bytes[i] == UInt8(ascii: ":") else {
            return nil
        }
        let isHeaderSeparator = bytes[i] == UInt8(ascii: ":")
        i += 1

        // Only a header separator may be followed by spaces. After `=` the value starts immediately:
        // a URL query and a cookie never space it out, and skipping here would let prose such as
        // "api_key= (missing)" read as a credential and swallow the rest of the line.
        var afterSpaces = i
        while afterSpaces < bytes.count, bytes[afterSpaces] == UInt8(ascii: " ") { afterSpaces += 1 }
        var quote: UInt8?
        if afterSpaces < bytes.count,
           bytes[afterSpaces] == UInt8(ascii: "\"") || bytes[afterSpaces] == UInt8(ascii: "'") {
            quote = bytes[afterSpaces]
            i = afterSpaces + 1
        } else if isHeaderSeparator {
            i = afterSpaces
        }
        let start = i

        if let quote {
            while i < bytes.count, bytes[i] != quote { i += 1 }
        } else {
            while i < bytes.count, !isValueTerminator(bytes[i]) { i += 1 }
        }
        return start < i ? start ..< i : nil
    }

    /// `:` counts, so `…&api_key=abc: timeout` gives the token back and keeps the error text. None of
    /// the credential shapes here (hex, base64url, percent-encoded cookie) contain a literal colon.
    private static func isValueTerminator(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "&"), UInt8(ascii: ";"), UInt8(ascii: ","), UInt8(ascii: ")"),
             UInt8(ascii: ">"), UInt8(ascii: ":"), UInt8(ascii: "\""), UInt8(ascii: "'"),
             UInt8(ascii: " "), 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    private static func isLetterOrDigit(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
    }

    private static func lowercased(_ b: UInt8) -> UInt8 {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ? b + 32 : b
    }
}
