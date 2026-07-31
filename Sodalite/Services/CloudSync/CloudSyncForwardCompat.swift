import Foundation

/// Keeps a device from deleting settings it is too old to see.
///
/// Every payload decodes newer fields with `decodeIfPresent`, so an older build reads a newer
/// record fine. The damage happens on the way back out: its encoder does not know those fields,
/// so its next upload is a complete payload without them, and last-writer-wins hands that to
/// every newer device as an authoritative reset. Carrying the fields it could not decode makes
/// its uploads additive instead.
///
/// Top level only, deliberately. A nested object is as likely to be a map whose absent keys are a
/// statement (the track memory entries, where eviction is meant to travel) as it is to be a struct
/// that grew a field, and this cannot tell those apart.
enum CloudSyncForwardCompat {

    private static let schemaVersionKey = "schemaVersion"

    /// Fields the remote payload carries that this build cannot write. Returns nil when there is
    /// nothing to carry.
    ///
    /// `known` must be every field this build could write, not the keys it happened to write this
    /// time: an optional that is nil right now is omitted from the JSON, and reading that as a
    /// field from the future is how an upload would resurrect the preference the user just
    /// cleared, on every device, forever.
    static func unknownFields(remote: Data, known: Set<String>) -> Data? {
        guard let remoteObject = object(from: remote) else { return nil }
        var unknown = remoteObject.filter { !known.contains($0.key) }
        guard !unknown.isEmpty else { return nil }
        // Not itself unknown, but a blob must never claim to be older than the content it carries,
        // so the version that goes with those fields travels along.
        if let remoteVersion = remoteObject[schemaVersionKey] as? Int {
            unknown[schemaVersionKey] = remoteVersion
        }
        return try? JSONSerialization.data(withJSONObject: unknown)
    }

    /// Re-attaches carried fields to an outgoing payload. What this build writes always wins; only
    /// keys it left out are filled in.
    static func merged(local: Data, carrying carried: Data?) -> Data {
        guard let carried,
              let carriedObject = object(from: carried),
              var localObject = object(from: local)
        else { return local }
        for (key, value) in carriedObject where localObject[key] == nil {
            localObject[key] = value
        }
        if let carriedVersion = carriedObject[schemaVersionKey] as? Int,
           let localVersion = localObject[schemaVersionKey] as? Int,
           carriedVersion > localVersion {
            localObject[schemaVersionKey] = carriedVersion
        }
        guard let data = try? JSONSerialization.data(withJSONObject: localObject) else { return local }
        return data
    }

    /// Stored property names of a payload. Equal to its coding keys for every payload here, which
    /// is what CloudSyncForwardCompatTests pins.
    static func storedPropertyNames(of payload: Any) -> Set<String> {
        Set(Mirror(reflecting: payload).children.compactMap(\.label))
    }

    private static func object(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
