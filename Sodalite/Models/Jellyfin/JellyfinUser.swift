import Foundation

struct JellyfinUser: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let serverID: String
    let hasPassword: Bool?
    let primaryImageTag: String?
    /// Server-side policy block. Sparse responses (e.g. `/Users/Public`)
    /// omit it; `/Users/Me` and `/Users/{id}` return it populated. The
    /// File-Management feature only reads `enableContentDeletion` and
    /// `isAdministrator` from here, but the struct decodes both as a
    /// dedicated sub-type so future per-feature flags can land here
    /// without re-touching the call sites.
    let policy: Policy?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverID = "ServerId"
        case hasPassword = "HasPassword"
        case primaryImageTag = "PrimaryImageTag"
        case policy = "Policy"
    }

    struct Policy: Codable, Sendable, Equatable {
        let isAdministrator: Bool
        let enableContentDeletion: Bool

        enum CodingKeys: String, CodingKey {
            case isAdministrator = "IsAdministrator"
            case enableContentDeletion = "EnableContentDeletion"
        }
    }

    /// True when the current user is allowed to delete content. Either
    /// the dedicated `EnableContentDeletion` flag is on, or the user is
    /// an administrator (admins implicitly have all rights in Jellyfin).
    /// Returns false when `policy` hasn't loaded yet, which is a
    /// conservative default for the brief window between session-restore
    /// and the first `getCurrentUser()` call.
    var canDeleteContent: Bool {
        guard let policy = policy else { return false }
        return policy.isAdministrator || policy.enableContentDeletion
    }
}
