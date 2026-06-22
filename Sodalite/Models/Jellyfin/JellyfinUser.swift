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

        enum CodingKeys: String, CodingKey {
            case isAdministrator = "IsAdministrator"
            case enableContentDeletion = "EnableContentDeletion"
        }
    }

    /// Admin (implicit all-rights) or EnableContentDeletion. False when `policy` is unloaded (conservative default pre first getCurrentUser()).
    var canDeleteContent: Bool {
        guard let policy = policy else { return false }
        return policy.isAdministrator || policy.enableContentDeletion
    }
}
