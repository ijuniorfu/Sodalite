import Foundation
#if os(tvOS)
import TVServices
#endif

/// Resolves the tvOS system user id under multi-user; nil otherwise (older models, single-user, non-tvOS). Callers treat nil as "no per-user routing."
enum TVUserContext {
    static var currentUserID: String? {
        #if os(tvOS)
        // Protocol-witness dispatch so the impl's deprecation marker doesn't propagate to this call site.
        let reader: any TVUserTokenReading = TVUserTokenReader()
        return reader.currentToken()
        #else
        return nil
        #endif
    }
}

#if os(tvOS)
private protocol TVUserTokenReading {
    func currentToken() -> String?
}

private struct TVUserTokenReader: TVUserTokenReading {
    /// `currentUserIdentifier` is deprecated (tvOS 16) but the only way to learn WHICH system user is active; the replacement (runs-as-current-user entitlement + user-independent keychain) hides identity entirely and would replace the whole profile-mapping feature. Deliberately kept.
    @available(tvOS, deprecated: 16.0, message: "Deliberate: only source of the per-user token.")
    func currentToken() -> String? {
        TVUserManager().currentUserIdentifier
    }
}
#endif
