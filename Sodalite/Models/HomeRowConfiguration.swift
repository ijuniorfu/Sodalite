import SwiftUI

enum HomeRowType: String, Codable, Sendable, CaseIterable, Identifiable {
    // Declaration order = default display order for fresh installs / Reset (defaultConfig uses allCases.enumerated()); existing users keep their saved order.
    case continueWatching
    case nextUp
    case myMedia
    case favorites
    case latestMovies
    case latestShows
    case discoverProviders
    case genres
    case collections
    case playlists
    case recentlyAdded
    case topRatedMovies
    case topRatedShows
    case allMovies
    case allSeries
    /// Dynamic per-library "Latest in <library>" row; never from `allCases`, only instantiated by reconciliation (fills libraryID/libraryName/collectionType).
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

    /// Row not sourced from Jellyfin (today only Discover/Jellyseerr): hardcoded provider list, pushes a Seerr-backed grid, not FilteredGridView.
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
        case .playlists: "home.playlists"
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
        case .playlists: "list.and.film"
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
    /// `.libraryLatest` only: scopes the Latest query and gives the row a stable identity across launches/server switches.
    var libraryID: String?
    var libraryName: String?
    /// `.libraryLatest` collectionType ("movies"/"tvshows"); drives which item type the Latest query asks for.
    var collectionType: String?

    /// Customize-list icon; `.libraryLatest` derives from collectionType so TV libraries don't get the "film" fallback (Sodalite#15).
    var systemImage: String {
        if type == .libraryLatest, collectionType == "tvshows" {
            return "tv"
        }
        return type.systemImage
    }

    /// `.libraryLatest` rows share an enum rawValue, so id folds in libraryID to stay unique/stable.
    var id: String {
        if type == .libraryLatest, let libraryID {
            return "libraryLatest:\(libraryID)"
        }
        return type.rawValue
    }

    static func defaultConfig() -> [HomeRowConfig] {
        // `.libraryLatest` is a template case; excluded here, added by reconciliation once libraries are known.
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

    /// Merge `stored` with server `libraries`: existing rows keep enabled/sortOrder, add a `.libraryLatest` per movies/tvshows lib (refresh name/type), drop vanished ones. Adaptive default: per-library rows start enabled only on multi-library servers, and on first such reconcile the aggregated latestMovies/latestShows start disabled.
    static func reconciled(
        stored: [HomeRowConfig],
        libraries: [JellyfinLibrary]
    ) -> [HomeRowConfig] {
        let latestLibs = libraries.filter {
            perLibraryLatestTypes.contains($0.collectionType ?? "")
        }
        let multiLibrary = latestLibs.count > 1
        let liveIDs = Set(latestLibs.map(\.id))

        // Any stored libraryLatest means the adaptive-default decision was already made; never re-flip the aggregated rows.
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
        // Track appended ids: duplicate library ids would yield colliding composite ids and break SwiftUI Identifiable/ForEach.
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

    /// Reset static rows to default order/enabled state; keep discovered `.libraryLatest` rows (at the end, disabled) so they don't vanish before the next reconcile.
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
