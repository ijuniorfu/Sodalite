import Foundation

/// Queries behind the two Recently Released rows, kept apart from `HomeViewModel` so the routing
/// decisions are testable without a server.
///
/// These rows order by release date, where every Latest row orders by `DateCreated`. That flips two
/// things around: titles that have not aired yet sort to the top instead of the bottom, and a
/// series' own `PremiereDate` is the wrong key (it is the date the show started, so a long-running
/// show that aired last night would sit at the bottom). Hence episodes plus a fold onto their
/// series, and a clamp on the release date.
enum HomeReleaseRowQuery {

    static func movies(now: Date, limit: Int) -> ItemQuery {
        ItemQuery(
            includeItemTypes: [.movie],
            sortBy: "PremiereDate,ProductionYear,SortName",
            sortOrder: "Descending",
            limit: limit,
            maxPremiereDate: now,
            fields: JellyfinEndpoint.homeRowFields
        )
    }

    /// Episodes, not series: the caller folds them onto their parent series. `limit` is expected to
    /// over-fetch, because several episodes of one show collapse into a single tile.
    static func episodes(now: Date, limit: Int) -> ItemQuery {
        ItemQuery(
            includeItemTypes: [.episode],
            sortBy: "PremiereDate",
            sortOrder: "Descending",
            limit: limit,
            isMissing: false,
            maxPremiereDate: now,
            fields: JellyfinEndpoint.homeRowFields
        )
    }

    /// Third net under `MaxPremiereDate` and `IsMissing`: an entry the library lists without holding
    /// a file cannot be opened, and `IsMissing` covers missing but not unaired ones (Sodalite#57).
    static func airedOnly(_ items: [JellyfinItem]) -> [JellyfinItem] {
        items.filter { !$0.isVirtual }
    }
}
