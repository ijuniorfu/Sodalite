import Foundation

/// Pure merge rules for cloud sync. No CloudKit types so everything unit-tests.
enum CloudSyncMerge {

    /// Stamps are issued monotonically: never at-or-below the highest stamp seen
    /// from any device, so clock skew between devices cannot let an older change
    /// outrank a newer one.
    static func monotonicStamp(now: Date, highestSeen: Date?) -> Date {
        guard let highestSeen, now <= highestSeen else { return now }
        return highestSeen.addingTimeInterval(0.001)
    }

    /// Last-writer-wins: remote replaces local only when strictly newer; ties stay put.
    static func remoteWins(localUpdatedAt: Date, remoteUpdatedAt: Date) -> Bool {
        remoteUpdatedAt > localUpdatedAt
    }

    /// First-adoption merge for a server present on BOTH sides. Local stamps are
    /// fabricated at adoption, so cloud wins for server info, password, and home
    /// rows; remembered users and Seerr sessions union (addedAt is real history).
    static func adoptServerPayload(local: ServerSyncPayload, cloud: ServerSyncPayload, stamp: Date) -> ServerSyncPayload {
        var merged = cloud
        merged.updatedAt = stamp
        merged.rememberedUsers = unionRememberedUsers(local: local.rememberedUsers, cloud: cloud.rememberedUsers)
        merged.seerrSessions = unionSeerrSessions(local: local.seerrSessions, cloud: cloud.seerrSessions)
        if merged.homeRows == nil { merged.homeRows = local.homeRows }
        if merged.jellyfinPassword == nil {
            merged.jellyfinPassword = local.jellyfinPassword
            merged.passwordUserID = local.passwordUserID
        }
        return merged
    }

    /// Union by user id; the newer addedAt wins per user. Sorted newest-first to
    /// match listRememberedUsers ordering.
    static func unionRememberedUsers(local: [RememberedUser], cloud: [RememberedUser]) -> [RememberedUser] {
        var byID: [String: RememberedUser] = [:]
        for user in local { byID[user.id] = user }
        for user in cloud {
            if let existing = byID[user.id], existing.addedAt > user.addedAt { continue }
            byID[user.id] = user
        }
        return byID.values.sorted { $0.addedAt > $1.addedAt }
    }

    /// Union by jellyfin user id; cloud wins collisions. Sorted for determinism.
    static func unionSeerrSessions(local: [RememberedSeerrSession], cloud: [RememberedSeerrSession]) -> [RememberedSeerrSession] {
        var byID: [String: RememberedSeerrSession] = [:]
        for session in local { byID[session.jellyfinUserID] = session }
        for session in cloud { byID[session.jellyfinUserID] = session }
        return byID.values.sorted { $0.jellyfinUserID < $1.jellyfinUserID }
    }
}
