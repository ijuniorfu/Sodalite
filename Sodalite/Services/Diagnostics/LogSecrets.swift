import AetherEngine
import Foundation

/// Names the credentials this process holds to both redactors, so they go by value wherever a line
/// carries them, in whatever encoding: the host's `LogRedaction` (lines Sodalite composes) and the
/// engine's (lines arriving through `EngineLog.handler`, plus its own OSLog output).
///
/// A value stays registered for the life of the process. Nothing here revokes a Jellyfin token or a
/// Seerr cookie on the server, so a value that left the session is still a working credential, and a
/// late engine line can still carry it.
nonisolated enum LogSecrets {

    static func register(_ secret: String) {
        LogRedaction.register(secret)
        EngineLog.registerSecret(secret)
    }

    /// The value of a `connect.sid=<value>` cookie, as sent and as decoded (`s%3A…` and `s:…`).
    static func registerCookie(_ cookie: String) {
        for value in cookieValues(cookie) { register(value) }
    }

    static func cookieValues(_ cookie: String) -> [String] {
        let pair = cookie.split(separator: ";", maxSplits: 1).first.map(String.init) ?? cookie
        guard let equals = pair.firstIndex(of: "=") else { return [] }
        let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return [] }
        var values = [value]
        if let decoded = value.removingPercentEncoding, decoded != value { values.append(decoded) }
        return values
    }

    // MARK: Live TV upstreams

    /// Shortest middle segment treated as a password. Below this a literal match would black out
    /// ordinary numbers (a channel id, a port) across every line.
    static let minimumUpstreamSecretLength = 6

    /// The password in an Xtream M3U short-form path, `/{user}/{password}/{stream}`. That form has no
    /// layout the redactor could recognise, so the value has to be named. Nil for any other depth:
    /// the long layouts (`/live/{user}/{password}/…`) are matched by `LogRedaction` itself.
    static func xtreamShortFormSecret(in url: URL) -> String? {
        let segments = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 3 else { return nil }
        let candidate = String(segments[1])
        return candidate.count >= minimumUpstreamSecretLength ? candidate : nil
    }

    /// Called where Sodalite takes a tuner upstream into custody, before the engine sees it.
    static func registerUpstreamCredentials(in url: URL) {
        if let secret = xtreamShortFormSecret(in: url) { register(secret) }
        if let password = url.password(percentEncoded: false), !password.isEmpty { register(password) }
    }

    /// How a tuner upstream is written into the log: scheme, host, port and the last path component.
    /// The rest of the path is where an IPTV provider puts the account, with nothing to name it.
    static func upstreamDescription(_ url: URL) -> String {
        var text = "\(url.scheme ?? "?")://\(url.host(percentEncoded: false) ?? "?")"
        if let port = url.port { text += ":\(port)" }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { text += "/.../\(last)" }
        return text
    }
}
