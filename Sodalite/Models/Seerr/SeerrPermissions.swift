import Foundation

/// Jellyseerr permissions bitfield; only the subset we check, mirroring `server/lib/permissions.ts`. Not the full 30+ bits (YAGNI, and unreferenced values can't catch typos).
struct SeerrPermissions: OptionSet, Sendable {
    let rawValue: Int

    // No `none` member: a rawValue-0 static shadows OptionSet's `[]` and trips the empty-option-set warning.
    static let admin          = SeerrPermissions(rawValue: 2)
    static let manageSettings = SeerrPermissions(rawValue: 4)
    static let manageUsers    = SeerrPermissions(rawValue: 8)
    static let manageRequests = SeerrPermissions(rawValue: 16)
    static let request        = SeerrPermissions(rawValue: 32)
    static let autoApprove    = SeerrPermissions(rawValue: 256)
}

extension SeerrUser {
    /// ADMIN bit implicitly grants all (per Jellyseerr), so OR it with manageRequests. False when `permissions == nil` (pre-field cached sessions).
    var canManageRequests: Bool {
        let mask = SeerrPermissions(rawValue: permissions ?? 0)
        return mask.contains(.admin) || mask.contains(.manageRequests)
    }
}
