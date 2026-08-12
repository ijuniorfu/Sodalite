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

    /// Takes the slots this instance leaves empty from `previous` (Sodalite#45). A login or
    /// discovery hit knows only the address it connected through, so an empty slot there means
    /// "not known right now", never "cleared". Only the iOS URL editor clears a slot, and it
    /// writes both slots explicitly instead of going through an upsert.
    func fillingEmptyURLSlots(from previous: JellyfinServer) -> JellyfinServer {
        guard internalURL == nil || externalURL == nil else { return self }
        return JellyfinServer(
            id: id,
            name: name,
            internalURL: internalURL ?? previous.internalURL,
            externalURL: externalURL ?? previous.externalURL,
            version: version
        )
    }
}
