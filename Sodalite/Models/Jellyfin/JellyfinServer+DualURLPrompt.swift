import Foundation

extension JellyfinServer {
    /// The single missing URL slot (if exactly one is empty), used to offer the
    /// other address after login. `nil` when both slots are already filled.
    var emptyURLSlot: ServerRoute? {
        if internalURL == nil { return .internal }
        if externalURL == nil { return .external }
        return nil
    }

    /// Compose the full (internal, external) pair by dropping `newURL` into
    /// `slot` and keeping the existing address in the other slot.
    func urls(filling slot: ServerRoute, with newURL: URL) -> (internal: URL?, external: URL?) {
        switch slot {
        case .internal: return (newURL, externalURL)
        case .external: return (internalURL, newURL)
        }
    }
}
