import Foundation

/// How the My Media library grids treat Jellyfin collections (Sodalite#44).
///
/// Jellyfin groups a BoxSet's movies into a single tile when the server option "Group movies into
/// collections" is on. That option is server-wide (`EnableGroupingMoviesIntoCollections`) and
/// admin-only to read, so the client cannot query it; it only takes effect while `CollapseBoxSetItems`
/// is absent from the request. `system` reproduces that, the other two override it per device.
enum CollectionGrouping: String, CaseIterable, Sendable {
    /// Leave the decision to the server, matching jellyfin-web.
    case system
    case always
    case never

    /// `ItemQuery.collapseBoxSetItems`. nil omits the param, which is what lets the server decide.
    var queryValue: Bool? {
        switch self {
        case .system: nil
        case .always: true
        case .never: false
        }
    }

    /// Tolerant read for UserDefaults and cloud payloads: an unknown or missing value is a fresh
    /// install or a mode written by a newer build, both of which should follow the server.
    init(storedValue: String?) {
        self = storedValue.flatMap(CollectionGrouping.init(rawValue:)) ?? .system
    }

    var localizedLabel: String {
        switch self {
        case .system:
            String(localized: "home.customize.collectionGrouping.system", defaultValue: "Server default")
        case .always:
            String(localized: "home.customize.collectionGrouping.always", defaultValue: "Always")
        case .never:
            String(localized: "home.customize.collectionGrouping.never", defaultValue: "Never")
        }
    }
}
