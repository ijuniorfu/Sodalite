import Foundation

/// Jellyseerr permissions bitfield. Mirrors the subset of
/// `server/lib/permissions.ts` we actually need to check on the
/// client. Adding new bits as more admin features land is a one-line
/// change. Don't enumerate the full set today (YAGNI; Jellyseerr has
/// 30+ bits, and the build can't catch a typo in a value we don't
/// reference).
struct SeerrPermissions: OptionSet, Sendable {
    let rawValue: Int

    // No `none` member: OptionSet's empty value is the `[]` literal,
    // and a rawValue-0 static both shadows it and trips the compiler's
    // empty-option-set warning. (It was never referenced anyway.)
    static let admin          = SeerrPermissions(rawValue: 2)
    static let manageSettings = SeerrPermissions(rawValue: 4)
    static let manageUsers    = SeerrPermissions(rawValue: 8)
    static let manageRequests = SeerrPermissions(rawValue: 16)
    static let request        = SeerrPermissions(rawValue: 32)
    static let autoApprove    = SeerrPermissions(rawValue: 256)
}

extension SeerrUser {
    /// Admin-feature gate. `ADMIN` bit implicitly grants every
    /// permission per Jellyseerr's evaluator, so we OR the two checks.
    /// Returns false when `permissions == nil`, which happens for
    /// cached sessions written before the field was decoded.
    var canManageRequests: Bool {
        let mask = SeerrPermissions(rawValue: permissions ?? 0)
        return mask.contains(.admin) || mask.contains(.manageRequests)
    }
}
