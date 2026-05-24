import Foundation

/// Surface for failures during a media-deletion flow. The `stage`
/// distinguishes Jellyfin failures (the item was never deleted) from
/// Seerr-cascade failures after Jellyfin already succeeded (the file
/// is gone from the library but the *arr-stack entry still exists).
/// The UI uses this distinction to tell the user whether to retry or
/// to expect orphan state.
///
/// `reason` further qualifies the failure so the UI can surface a
/// specific toast. Today the only special case is "not signed into
/// Seerr": the user enabled the *arr cascade without an active Seerr
/// session, which is otherwise indistinguishable from a generic API
/// error in the message stream. Pre-flight detection keeps the toast
/// honest ("you're not signed in") instead of vague ("could not be
/// removed").
struct MediaDeletionError: Error, Sendable {
    enum Stage: Sendable { case jellyfin, seerr }
    enum Reason: Sendable {
        case generic
        case seerrNotSignedIn
    }
    let stage: Stage
    let reason: Reason
    let underlying: Error?
    /// True when Jellyfin succeeded but Seerr failed afterwards. The
    /// caller surfaces a different toast in that case.
    var partialSuccess: Bool { stage == .seerr }

    init(stage: Stage, reason: Reason = .generic, underlying: Error? = nil) {
        self.stage = stage
        self.reason = reason
        self.underlying = underlying
    }
}
