import Foundation

struct SeerrUser: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let email: String?
    let username: String?
    let displayName: String?
    let avatar: String?
    let userType: Int?
    let requestCount: Int?
    /// Jellyseerr permissions bitfield, decoded from `/api/v1/auth/me`.
    /// Optional because older Jellyseerr installs (pre-1.x) may omit it,
    /// and any cached `SeerrUser` snapshots stored before this field was
    /// introduced (in `RememberedSeerrSession`) ship without it. Default
    /// treatment when nil: no admin rights. See `SeerrPermissions` for
    /// the bit values; use `canManageRequests` for the only check we
    /// actually surface in UI today.
    let permissions: Int?

    var resolvedDisplayName: String {
        displayName ?? username ?? email ?? "User \(id)"
    }
}
