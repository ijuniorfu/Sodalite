import Foundation

/// Pure policy for holding the remembered profiles of one server against that server's own user
/// table (Sodalite#90). Remembered profiles are a local cache of a server-owned fact, and nothing
/// used to re-read that fact: a user deleted on the server kept a card in every picker, and picking
/// it entered a session no request would be answered for.
///
/// Two rules keep a reconcile from removing a profile the server never dropped. The removal is
/// recorded as a tombstone and travels to every synced device, so a wrong verdict here is expensive
/// and a withheld one costs nothing but a stale card until the next pass.
enum RememberedProfileReconciliation {
    /// Remembered profiles absent from `serverUserIDs`, in the ids the local store knows them by.
    /// Empty when the answer is not one to act on:
    ///
    /// - an empty user table is a response about something other than a running Jellyfin (a proxy,
    ///   a filtered listing, a server mid-restore), never a household that deleted everyone;
    /// - a table that does not carry the session's own user is not describing the table this
    ///   session lives in, so it cannot speak for the profiles beside it either.
    static func staleProfileIDs(
        remembered: [RememberedUser],
        serverUserIDs: [String],
        activeUserID: String?
    ) -> [String] {
        let known = Set(serverUserIDs.map(normalized))
        guard !known.isEmpty else { return [] }
        if let activeUserID, !known.contains(normalized(activeUserID)) { return [] }
        return remembered
            .filter { !known.contains(normalized($0.id)) }
            .map(\.id)
    }

    /// Whether the server's answer leaves the session's own user out. True for two situations that
    /// look identical from here (the table belongs to another backend / the active profile is the
    /// user that was deleted), which is why `staleProfileIDs` refuses to judge either of them: the
    /// caller has to tell them apart by asking whether the token still resolves.
    static func sessionUserIsAbsent(from serverUserIDs: [String], activeUserID: String?) -> Bool {
        guard let activeUserID, !serverUserIDs.isEmpty else { return false }
        return !Set(serverUserIDs.map(normalized)).contains(normalized(activeUserID))
    }

    /// Jellyfin serialises the same GUID with and without dashes depending on where it came from
    /// (an auth response, a user listing, an older install's stored copy). Compare on the digits.
    private static func normalized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
