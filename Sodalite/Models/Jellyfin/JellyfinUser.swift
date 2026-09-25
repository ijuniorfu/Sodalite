import Foundation

struct JellyfinUser: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let serverID: String
    let hasPassword: Bool?
    let primaryImageTag: String?
    /// Server-side policy; omitted by sparse responses (`/Users/Public`), populated by `/Users/Me` and `/Users/{id}`.
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
        /// Optional with a default so older persisted copies and the hand-written inits stay valid; nil
        /// reads as "not granted" / "restricted" wherever a gate consults it.
        var enableLiveTvManagement: Bool? = nil
        var enableAllFolders: Bool? = nil
        var maxParentalRating: Int? = nil
        var blockedTags: [String]? = nil
        var allowedTags: [String]? = nil
        var blockUnratedItems: [String]? = nil

        enum CodingKeys: String, CodingKey {
            case isAdministrator = "IsAdministrator"
            case enableContentDeletion = "EnableContentDeletion"
            case enableLiveTvManagement = "EnableLiveTvManagement"
            case enableAllFolders = "EnableAllFolders"
            case maxParentalRating = "MaxParentalRating"
            case blockedTags = "BlockedTags"
            case allowedTags = "AllowedTags"
            case blockUnratedItems = "BlockUnratedItems"
        }
    }

    /// Admin (implicit all-rights) or EnableContentDeletion. False when `policy` is unloaded (conservative default pre first getCurrentUser()).
    var canDeleteContent: Bool {
        guard let policy = policy else { return false }
        return policy.isAdministrator || policy.enableContentDeletion
    }

    /// Nothing in the policy keeps library items from this user: every folder, no rating ceiling, no tag
    /// filter. Jellyfin answers 404 for an item the user may not see exactly as for one that is gone, so
    /// only for this user does a 404 on a known item id prove the item was deleted.
    var seesWholeLibrary: Bool {
        guard let policy else { return false }
        return policy.enableAllFolders == true
            && policy.maxParentalRating == nil
            && (policy.blockedTags ?? []).isEmpty
            && (policy.allowedTags ?? []).isEmpty
            && (policy.blockUnratedItems ?? []).isEmpty
    }
}
