import Foundation

struct SeerrUser: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let email: String?
    let username: String?
    let displayName: String?
    let avatar: String?
    let userType: Int?
    let requestCount: Int?
    /// Permissions bitfield from `/api/v1/auth/me`; optional (pre-1.x installs / pre-field cached sessions omit it), nil means no admin rights. See `SeerrPermissions` / `canManageRequests`.
    let permissions: Int?

    var resolvedDisplayName: String {
        displayName ?? username ?? email ?? "User \(id)"
    }
}
