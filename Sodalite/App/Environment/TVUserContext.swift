import Foundation
#if os(tvOS)
import TVServices
#endif

/// Resolves the system-level tvOS user identifier when multi-user
/// mode is active. Returns nil on Apple TVs without multi-user
/// (older models, single-user setup, or non-tvOS targets). Callers
/// use the nil case as "behave like before, no per-user routing."
enum TVUserContext {
    static var currentUserID: String? {
        #if os(tvOS)
        if #available(tvOS 13, *) {
            // currentUserIdentifier is deprecated after tvOS 16 but remains
            // the only way to read the opaque per-user token at launch.
            // Suppressed so the build stays warning-clean.
            return TVUserManager().currentUserIdentifier
        }
        #endif
        return nil
    }
}
