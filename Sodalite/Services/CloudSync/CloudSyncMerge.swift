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
        let resolved = resolveRememberedUsers(
            local: local.rememberedUsers,
            cloud: cloud.rememberedUsers,
            localForgotten: local.forgottenUsers ?? [:],
            cloudForgotten: cloud.forgottenUsers ?? [:]
        )
        merged.rememberedUsers = resolved.users
        merged.forgottenUsers = resolved.forgotten.isEmpty ? nil : resolved.forgotten
        merged.seerrSessions = unionSeerrSessions(local: local.seerrSessions, cloud: cloud.seerrSessions)
        if merged.isDefaultServer == nil { merged.isDefaultServer = local.isDefaultServer }
        if merged.homeRows == nil { merged.homeRows = local.homeRows }
        if merged.defaultUserID == nil { merged.defaultUserID = local.defaultUserID }
        if merged.jellyfinPassword == nil {
            merged.jellyfinPassword = local.jellyfinPassword
            merged.passwordUserID = local.passwordUserID
        }
        // Union per profile, local wins: a password this device knows is first-hand knowledge, and
        // the cloud copy can only be the same secret or a stale one.
        if local.jellyfinPasswords?.isEmpty == false || merged.jellyfinPasswords?.isEmpty == false {
            var passwords = merged.jellyfinPasswords ?? [:]
            for (userID, password) in local.jellyfinPasswords ?? [:] {
                passwords[userID] = password
            }
            merged.jellyfinPasswords = passwords.isEmpty ? nil : passwords
        }
        return merged
    }

    /// Sodalite#45. The remembered list unions, so a removal has to travel as a removal: a device
    /// whose list is merely behind would otherwise publish it as an authoritative prune. A removal
    /// holds the profile out until a sign-in NEWER than the removal arrives, which is the only thing
    /// that distinguishes a deliberate re-add from a device that has not heard about the removal yet.
    /// Without that date the removal and the re-add would fight forever: each side would keep handing
    /// the other back what it just dropped.
    static func resolveRememberedUsers(
        local: [RememberedUser],
        cloud: [RememberedUser],
        localForgotten: [String: Date],
        cloudForgotten: [String: Date]
    ) -> (users: [RememberedUser], forgotten: [String: Date]) {
        var forgotten = localForgotten
        for (id, removedAt) in cloudForgotten {
            forgotten[id] = max(forgotten[id] ?? removedAt, removedAt)
        }
        var users: [RememberedUser] = []
        for user in unionRememberedUsers(local: local, cloud: cloud) {
            guard let removedAt = forgotten[user.id] else {
                users.append(user)
                continue
            }
            guard user.addedAt > removedAt else { continue }
            forgotten.removeValue(forKey: user.id)
            users.append(user)
        }
        return (users, forgotten)
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

    /// Sodalite#46. Union by scope key, newest entry per key wins. Eviction deliberately
    /// does not propagate: an evicted entry coming back from the cloud is less harmful
    /// than a lost selection. The cap is re-applied so both devices converge on one set.
    static func unionTrackMemory(local: TrackMemoryPayload, cloud: TrackMemoryPayload) -> TrackMemoryPayload {
        var byKey = local.entries
        for (key, entry) in cloud.entries {
            if let existing = byKey[key], existing.updatedAt >= entry.updatedAt { continue }
            byKey[key] = entry
        }
        return TrackMemoryPayload(
            updatedAt: max(local.updatedAt, cloud.updatedAt),
            entries: TrackSelectionMemory.capped(byKey)
        )
    }

    /// Sodalite#50. Union by reveal key, later reveal wins. Same shape as unionTrackMemory:
    /// eviction deliberately does not propagate, and the cap is re-applied so both devices
    /// converge on one set.
    static func unionSpoilerReveals(local: SpoilerRevealPayload, cloud: SpoilerRevealPayload) -> SpoilerRevealPayload {
        var byKey = local.entries
        for (key, revealedAt) in cloud.entries {
            if let existing = byKey[key], existing >= revealedAt { continue }
            byKey[key] = revealedAt
        }
        return SpoilerRevealPayload(
            updatedAt: max(local.updatedAt, cloud.updatedAt),
            entries: SpoilerRevealMemory.capped(byKey)
        )
    }
}
