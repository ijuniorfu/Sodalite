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
        // Dispatch through the protocol witness below so the
        // deprecation marker on the concrete impl doesn't propagate
        // here (a directly-called deprecated wrapper just moves the
        // warning to its call site).
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
    /// `currentUserIdentifier` is deprecated since tvOS 16, but it is
    /// the only way to learn WHICH system user is active; the suggested
    /// replacement (runs-as-current-user entitlement + user-independent
    /// keychain) is a different model in which the app never sees the
    /// user identity at all, which would replace the whole profile-
    /// mapping feature. Deliberately kept; the deprecation marker on
    /// this impl silences the API warning inside the body.
    @available(tvOS, deprecated: 16.0, message: "Deliberate: only source of the per-user token.")
    func currentToken() -> String? {
        TVUserManager().currentUserIdentifier
    }
}
#endif
