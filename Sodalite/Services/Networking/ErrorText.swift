import Foundation

/// The single way an `Error` becomes text a viewer reads.
///
/// `error.localizedDescription` is not that way. On a Swift type that does not conform to
/// `LocalizedError` it renders the bridged NSError fallback, which is the type's own name:
/// "The operation couldn't be completed. (Sodalite.DependencyContainer.ServerSwitchError error 0.)".
/// That sentence shipped to viewers of a 26-language app, and no locale changes it, because the
/// untranslated half is a Swift identifier.
///
/// Two rules keep it out. Every error type this app declares conforms to `LocalizedError` with
/// `String(localized:)` copy, pinned by `ErrorTextCoverageTests` so a new type cannot quietly skip it.
/// And every UI call site asks here rather than reading `localizedDescription`, so a foreign type
/// nobody anticipated still lands on a translated sentence instead of a Swift identifier.
enum ErrorText {

    /// A sentence for the viewer.
    ///
    /// Our own types answer through `LocalizedError`. Foreign ones (Foundation, AVFoundation,
    /// StoreKit, CloudKit) carry an OS-localized `localizedDescription` and keep it, since the system
    /// translates those into the device's language and describes the failure better than a generic
    /// line would. Anything that arrives with neither gets the generic line: it is the one case where
    /// saying less is saying more, because the alternative names a Swift type at the viewer.
    static func user(for error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        if isBridgedSwiftError(error) {
            return unexpected
        }
        let system = error.localizedDescription
        return system.isEmpty ? unexpected : system
    }

    /// Generic line for a failure nothing could name.
    static var unexpected: String {
        String(
            localized: "error.unexpected",
            defaultValue: "Something went wrong. Please try again."
        )
    }

    /// True where `localizedDescription` would render the bridged fallback naming the Swift type.
    ///
    /// Read off the domain rather than off the rendered sentence: the sentence is localized, and
    /// matching on a localized string is matching on the device's language. Foundation builds the
    /// domain of a bridged Swift error from the type's fully qualified name, so it carries the module
    /// separator that no system domain ("NSURLErrorDomain", "NSCocoaErrorDomain", "CKErrorDomain",
    /// "SKErrorDomain", "AVFoundationErrorDomain") has. A system error that did localize itself never
    /// reaches this check, because it answered above.
    private static func isBridgedSwiftError(_ error: Error) -> Bool {
        let domain = (error as NSError).domain
        return domain.contains(".") && !domain.hasPrefix("com.apple.")
    }
}
