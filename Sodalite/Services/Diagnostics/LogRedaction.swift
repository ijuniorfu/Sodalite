import Foundation

/// Strips credentials out of a diagnostic line before it enters `LogTap`.
///
/// The log exists to be handed to someone else: a screenshot in a GitHub issue, a paste into Discord.
/// Jellyfin puts the access token in the QUERY (`api_key=` on every stream and image URL), and both the
/// engine and the host log whole URLs (`[AetherEngine] load url=`, `[NativeAVPlayerHost] load url=`,
/// `[Image] fetch failed`), so an unfiltered log is a live credential the moment a user shares it.
///
/// Placed on the `LogTap.note(_:)` funnel rather than at each call site on purpose: every engine line
/// arrives through the same door, so a log line added upstream tomorrow is covered without anyone
/// remembering this file. Over-redaction is the safe failure here, under-redaction is the leak.
///
/// The redacted value is replaced whole, not truncated to a prefix: a prefix would still narrow a
/// brute-force and buys nothing a playback bug needs. Everything else about the URL (host, path, item
/// id, container, bitrate, subtitle index) survives, which is the part that answers the bug.
nonisolated enum LogRedaction {

    static let placeholder = "<redacted>"

    /// Matched case-insensitively, longest first so `x-emby-token` wins over its `token` suffix.
    /// `token` alone is deliberately broad; it only fires when the preceding character is not
    /// alphanumeric, so `hasToken` and `refreshTokenAt` do not match.
    private static let secretKeys: [[Character]] = [
        "x-mediabrowser-token", "x-emby-token", "connect.sid", "api_key", "apikey", "token",
    ].map(Array.init)

    static func redact(_ line: String) -> String {
        // Cheap reject: the overwhelming majority of lines carry no credential at all.
        guard containsAnyKey(line) else { return line }

        let chars = Array(line)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0

        while i < chars.count {
            guard let key = matchedKey(in: chars, at: i),
                  let value = valueRange(in: chars, after: i + key.count) else {
                out.append(chars[i])
                i += 1
                continue
            }
            out.append(contentsOf: chars[i ..< value.lowerBound])
            out.append(placeholder)
            i = value.upperBound
        }
        return out
    }

    private static func containsAnyKey(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return secretKeys.contains { lowered.contains(String($0)) }
    }

    /// The key must start on a boundary, else `token` would fire inside `hasToken`. A separator like
    /// the `-` in `X-Emby-Token` or the `_` in `api_key` is a boundary; a letter or digit is not.
    private static func matchedKey(in chars: [Character], at index: Int) -> [Character]? {
        if index > 0, chars[index - 1].isLetter || chars[index - 1].isNumber { return nil }
        return secretKeys.first { key in
            guard index + key.count <= chars.count else { return false }
            return zip(key, chars[index ..< index + key.count]).allSatisfy {
                $0 == Character($1.lowercased())
            }
        }
    }

    /// The span holding the secret, given the index just past the key. Handles the query form
    /// (`api_key=abc&next=1`), the header forms (`Token="abc"`, `X-Emby-Token: abc`) and the cookie
    /// form (`connect.sid=abc; Path=/`). Returns nil when there is no assignment or the value is
    /// empty, so `api_key=` and a bare `token` in prose are left alone.
    private static func valueRange(in chars: [Character], after keyEnd: Int) -> Range<Int>? {
        var i = keyEnd
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == "=" || chars[i] == ":" else { return nil }
        let isHeaderSeparator = chars[i] == ":"
        i += 1

        // Only a header separator may be followed by spaces. After `=` the value starts immediately:
        // a URL query and a cookie never space it out, and skipping here would let prose such as
        // "api_key= (missing)" read as a credential and swallow the rest of the line.
        var afterSpaces = i
        while afterSpaces < chars.count, chars[afterSpaces] == " " { afterSpaces += 1 }
        var quote: Character?
        if afterSpaces < chars.count, chars[afterSpaces] == "\"" || chars[afterSpaces] == "'" {
            quote = chars[afterSpaces]
            i = afterSpaces + 1
        } else if isHeaderSeparator {
            i = afterSpaces
        }
        let start = i

        if let quote {
            while i < chars.count, chars[i] != quote { i += 1 }
        } else {
            while i < chars.count, !isValueTerminator(chars[i]) { i += 1 }
        }
        return start < i ? start ..< i : nil
    }

    /// `:` counts, so `…&ApiKey=abc: timeout` gives the token back and keeps the error text. None of
    /// the credential shapes here (hex, base64url, percent-encoded cookie) contain a literal colon.
    private static func isValueTerminator(_ c: Character) -> Bool {
        c == "&" || c == ";" || c == "," || c == ")" || c == ">" || c == ":" || c == "\"" || c == "'"
            || c.isWhitespace
    }
}
