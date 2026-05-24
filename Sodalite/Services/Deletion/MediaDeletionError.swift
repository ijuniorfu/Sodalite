import Foundation

/// Surface for failures during a media-deletion flow. The `stage`
/// distinguishes Jellyfin failures (the item was never deleted) from
/// Seerr-cascade failures after Jellyfin already succeeded (the file
/// is gone from the library but the *arr-stack entry still exists).
/// The UI uses this distinction to tell the user whether to retry or
/// to expect orphan state.
struct MediaDeletionError: Error, Sendable {
    enum Stage: Sendable { case jellyfin, seerr }
    let stage: Stage
    let underlying: Error
    /// True when Jellyfin succeeded but Seerr failed afterwards. The
    /// caller surfaces a different toast in that case.
    var partialSuccess: Bool { stage == .seerr }
}
