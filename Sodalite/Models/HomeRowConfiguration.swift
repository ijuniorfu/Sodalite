import SwiftUI

enum HomeRowType: String, Codable, Sendable, CaseIterable, Identifiable {
    // Declaration order is the default display order for new installs
    // (defaultConfig() uses allCases.enumerated() for sortOrder). Existing
    // users keep whatever order they saved; this only affects fresh
    // installs and a Reset-to-Default.
    case continueWatching
    case nextUp
    case myMedia
    case favorites
    case latestMovies
    case latestShows
    case discoverProviders
    case genres
    case collections
    case recentlyAdded
    case topRatedMovies
    case topRatedShows
    case allMovies
    case allSeries
    /// Dynamic, per-library "Latest in <library>" row. Never created
    /// from `allCases`; only ever instantiated by reconciliation
    /// against the server's libraries, which fills in the libraryID /
    /// libraryName / collectionType on the owning HomeRowConfig.
    case libraryLatest

    var id: String { rawValue }

    var defaultEnabled: Bool {
        switch self {
        case .continueWatching, .nextUp, .myMedia, .favorites, .latestMovies,
             .latestShows, .discoverProviders, .genres:
            true
        default:
            false
        }
    }

    var cardStyle: MediaCardStyle {
        switch self {
        case .continueWatching, .nextUp:
            .landscape
        default:
            .poster
        }
    }

    var usesBackdrop: Bool {
        switch self {
        case .continueWatching, .nextUp:
            true
        default:
            false
        }
    }

    /// Genres show tag cards rather than media items.
    var isTagRow: Bool {
        switch self {
        case .genres:
            true
        default:
            false
        }
    }

    /// True for rows whose contents are *not* sourced from Jellyfin,
    /// today only the Discover (Jellyseerr) streaming-provider row,
    /// which renders a hardcoded provider list with TMDB logos and
    /// pushes a Jellyseerr-backed filter grid instead of the local
    /// FilteredGridView.
    var isDiscoverProviderRow: Bool { self == .discoverProviders }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .continueWatching: "home.continueWatching"
        case .nextUp: "home.nextUp"
        case .latestMovies: "home.latestMovies"
        case .latestShows: "home.latestShows"
        case .allMovies: "home.allMovies"
        case .allSeries: "home.allSeries"
        case .favorites: "home.favorites"
        case .topRatedMovies: "home.topRatedMovies"
        case .topRatedShows: "home.topRatedShows"
        case .recentlyAdded: "home.recentlyAdded"
        case .genres: "home.genres"
        case .collections: "home.collections"
        case .discoverProviders: "home.discoverProviders"
        case .myMedia: "home.myMedia"
        case .libraryLatest: "home.latestMovies"
        }
    }

    var systemImage: String {
        switch self {
        case .continueWatching: "play.circle"
        case .nextUp: "forward"
        case .latestMovies: "film"
        case .latestShows: "tv"
        case .allMovies: "film.stack"
        case .allSeries: "rectangle.stack"
        case .favorites: "heart.fill"
        case .topRatedMovies: "star.fill"
        case .topRatedShows: "star.fill"
        case .recentlyAdded: "clock"
        case .genres: "tag"
        case .collections: "rectangle.stack.fill"
        case .discoverProviders: "tv.badge.wifi"
        case .myMedia: "rectangle.grid.2x2"
        case .libraryLatest: "film"
        }
    }
}

struct HomeRowConfig: Codable, Sendable, Identifiable, Equatable {
    let type: HomeRowType
    var isEnabled: Bool
    var sortOrder: Int
    /// Set only for `.libraryLatest` rows. Jellyfin library id, used
    /// to scope the Latest query and to give the row a stable identity
    /// across launches and server switches.
    var libraryID: String?
    /// Display name for a `.libraryLatest` row (the library's name).
    var libraryName: String?
    /// Jellyfin collectionType ("movies" / "tvshows") for a
    /// `.libraryLatest` row; drives which item type the Latest query
    /// asks for.
    var collectionType: String?

    /// Icon for the customize list. `.libraryLatest` rows pick it from
    /// the library's collectionType; the type-level fallback ("film")
    /// would slap a movies icon onto TV libraries (Sodalite#15).
    var systemImage: String {
        if type == .libraryLatest, collectionType == "tvshows" {
            return "tv"
        }
        return type.systemImage
    }

    /// `.libraryLatest` rows share the same enum rawValue, so identity
    /// has to fold in the libraryID to stay unique and stable.
    var id: String {
        if type == .libraryLatest, let libraryID {
            return "libraryLatest:\(libraryID)"
        }
        return type.rawValue
    }

    static func defaultConfig() -> [HomeRowConfig] {
        // `.libraryLatest` is a template case, never a standalone row,
        // so it's excluded here; reconciliation adds the real per-
        // library rows once the server's libraries are known.
        HomeRowType.allCases
            .filter { $0 != .libraryLatest }
            .enumerated()
            .map { index, type in
                HomeRowConfig(type: type, isEnabled: type.defaultEnabled, sortOrder: index)
            }
    }
}

extension HomeRowConfig {
    /// Library types that get their own per-library "Latest" row.
    static let perLibraryLatestTypes: Set<String> = ["movies", "tvshows"]

    /// Merge `stored` with the server's `libraries`:
    /// - existing rows keep their enabled flag and sortOrder,
    /// - a `.libraryLatest` row is added for each movies/tvshows
    ///   library not already present (libraryName/collectionType
    ///   refreshed in case they changed server-side),
    /// - `.libraryLatest` rows whose library no longer exists drop out,
    /// - adaptive default: new per-library rows start enabled only when
    ///   the server has more than one movies/tvshows library (so single-
    ///   library servers keep the aggregated Latest rows), and when any
    ///   per-library rows are enabled by that rule on a fresh reconcile,
    ///   the aggregated `.latestMovies` / `.latestShows` start disabled.
    static func reconciled(
        stored: [HomeRowConfig],
        libraries: [JellyfinLibrary]
    ) -> [HomeRowConfig] {
        let latestLibs = libraries.filter {
            perLibraryLatestTypes.contains($0.collectionType ?? "")
        }
        let multiLibrary = latestLibs.count > 1
        let liveIDs = Set(latestLibs.map(\.id))

        // Has the user already seen per-library rows for this server?
        // If any libraryLatest config exists in storage we treat the
        // adaptive-default decision as already made and never re-flip
        // the aggregated rows again.
        let firstReconcile = !stored.contains { $0.type == .libraryLatest }

        var result = stored.filter { config in
            // Drop dynamic rows whose library vanished.
            if config.type == .libraryLatest {
                return config.libraryID.map { liveIDs.contains($0) } ?? false
            }
            return true
        }

        // Refresh name/collectionType on surviving dynamic rows.
        for i in result.indices where result[i].type == .libraryLatest {
            if let lib = latestLibs.first(where: { $0.id == result[i].libraryID }) {
                result[i].libraryName = lib.name
                result[i].collectionType = lib.collectionType
            }
        }

        // Append rows for libraries not yet represented.
        var nextOrder = (result.map(\.sortOrder).max() ?? -1) + 1
        // Track appended ids too, so a server that ever returns two
        // libraries with the same id can't produce two rows sharing a
        // composite id (which would break SwiftUI Identifiable/ForEach).
        var knownIDs = Set(result.compactMap { $0.type == .libraryLatest ? $0.libraryID : nil })
        for lib in latestLibs where !knownIDs.contains(lib.id) {
            result.append(
                HomeRowConfig(
                    type: .libraryLatest,
                    isEnabled: multiLibrary,
                    sortOrder: nextOrder,
                    libraryID: lib.id,
                    libraryName: lib.name,
                    collectionType: lib.collectionType
                )
            )
            knownIDs.insert(lib.id)
            nextOrder += 1
        }

        // On the very first reconcile for a multi-library server, turn
        // the aggregated Latest rows off so the per-library rows are
        // what the user sees out of the box.
        if firstReconcile && multiLibrary {
            for i in result.indices {
                if result[i].type == .latestMovies || result[i].type == .latestShows {
                    result[i].isEnabled = false
                }
            }
        }

        return result
    }

    /// Reset that preserves discovered `.libraryLatest` rows (so they
    /// don't vanish from the customize list until the next reconcile)
    /// while restoring static rows to their default order and enabled
    /// state. Library rows go to the end, disabled.
    static func resetToDefault(current: [HomeRowConfig]) -> [HomeRowConfig] {
        var result = defaultConfig()
        var order = result.count
        for config in current where config.type == .libraryLatest {
            result.append(
                HomeRowConfig(
                    type: .libraryLatest,
                    isEnabled: false,
                    sortOrder: order,
                    libraryID: config.libraryID,
                    libraryName: config.libraryName,
                    collectionType: config.collectionType
                )
            )
            order += 1
        }
        return result
    }
}
