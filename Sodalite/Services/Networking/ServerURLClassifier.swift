import Foundation

/// Heuristic used when a server only carries one URL (legacy records, first
/// login): decides which slot the address belongs to. Users can correct the
/// result in the iOS edit sheet, so this only needs to be right for the
/// common cases. Tailscale CGNAT (100.64.0.0/10) intentionally classifies as
/// external: it is reachable away from home via VPN.
enum ServerURLClassifier {
    private static let internalSuffixes = [".local", ".lan", ".home", ".home.arpa", ".internal"]

    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if let octets = ipv4Octets(host) { return isPrivateIPv4(octets) }
        if host.contains(":") { return isInternalIPv6(host) }
        if !host.contains(".") { return true }
        return internalSuffixes.contains { host.hasSuffix($0) }
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _), (127, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    private static func isInternalIPv6(_ host: String) -> Bool {
        // URL.host() strips brackets; a zone id (%en0) may trail link-local addresses.
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        if bare == "::1" { return true }
        if bare.hasPrefix("fc") || bare.hasPrefix("fd") { return true }
        return bare.hasPrefix("fe8") || bare.hasPrefix("fe9")
            || bare.hasPrefix("fea") || bare.hasPrefix("feb")
    }
}
