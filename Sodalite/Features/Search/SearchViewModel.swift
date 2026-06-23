import Foundation
import Observation

@MainActor
@Observable
final class SearchViewModel {
    var query: String = ""
    var jellyfinResults: [JellyfinItem] = []
    var seerrResults: [SeerrMedia] = []
    var isSearching = false
    var errorMessage: String?

    private let itemService: JellyfinItemServiceProtocol
    /// `var` so SearchView can flip nil→service when Seerr connects after the search tab is already open; otherwise a cold-start tap pins the catalog half at nil for the session.
    var seerrSearchService: SeerrSearchServiceProtocol?
    private let userID: String
    private var searchTask: Task<Void, Never>?

    /// Monotonic in-flight search ID; only the run still matching `currentSearchID` may publish. `Task.isCancelled` alone is insufficient since network helpers swallow cancellation into `[]`, which would wipe a newer search's results.
    private var currentSearchID: UInt64 = 0

    init(
        itemService: JellyfinItemServiceProtocol,
        seerrSearchService: SeerrSearchServiceProtocol?,
        userID: String
    ) {
        self.itemService = itemService
        self.seerrSearchService = seerrSearchService
        self.userID = userID
    }

    /// Debounced search; cancels the prior task so fast typing only runs the final query (saves bandwidth, avoids out-of-order results).
    func scheduleSearch() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            // Bump the ID so in-flight tasks can't write; the cleared state owns the newest "search".
            currentSearchID &+= 1
            jellyfinResults = []
            seerrResults = []
            isSearching = false
            errorMessage = nil
            return
        }

        currentSearchID &+= 1
        let id = currentSearchID

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await self.runSearch(query: trimmed, id: id)
        }
    }

    private func runSearch(query: String, id: UInt64) async {
        isSearching = true
        errorMessage = nil

        async let jfTask = searchJellyfin(query: query)
        async let seerrTask = searchSeerr(query: query)

        let jfResult = await jfTask
        let seerrResult = await seerrTask

        // Publish only if still the latest search; a superseded run must not overwrite results nor flip isSearching to false while a fresher run is mid-flight.
        guard id == currentSearchID else { return }

        let jfItems = jfResult.items
        jellyfinResults = jfItems
        seerrResults = deduplicate(seerr: seerrResult.items, against: jfItems)
        isSearching = false

        // Connection failure vs "no results": Jellyfin is the primary signal; only its error + both lists empty means network problem. Seerr alone can't trigger this (may be intentionally disconnected).
        if jfResult.error != nil && jellyfinResults.isEmpty && seerrResults.isEmpty {
            errorMessage = String(
                localized: "search.error.connection",
                defaultValue: "Couldn't reach your server. Check the connection and try again."
            )
        }
    }

    private struct ServiceResult<T> {
        let items: [T]
        let error: Error?
    }

    private func searchJellyfin(query: String) async -> ServiceResult<JellyfinItem> {
        let q = ItemQuery(
            includeItemTypes: [.movie, .series],
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 30,
            searchTerm: query
        )
        do {
            let resp = try await itemService.getCollectionItems(userID: userID, query: q)
            return ServiceResult(items: resp.items, error: nil)
        } catch {
            return ServiceResult(items: [], error: error)
        }
    }

    private func searchSeerr(query: String) async -> ServiceResult<SeerrMedia> {
        guard let service = seerrSearchService else {
            return ServiceResult(items: [], error: nil)
        }
        do {
            let result = try await service.search(query: query, page: 1)
            return ServiceResult(items: result.results, error: nil)
        } catch {
            return ServiceResult(items: [], error: error)
        }
    }

    /// Remove Seerr results already in the Jellyfin library. Both keys are qualified by media type:
    /// TMDB reuses numeric ids across the movie and tv namespaces (mirrors SeerrMedia.stableKey), so
    /// an owned movie must not suppress a different series sharing that id (or the same title+year).
    /// Primary key: type + TMDB id; fallback (no TMDB provider id, e.g. manual imports/old scanner):
    /// type + normalized title + production year.
    private func deduplicate(seerr: [SeerrMedia], against jellyfin: [JellyfinItem]) -> [SeerrMedia] {
        func seerrType(_ type: ItemType) -> String? {
            switch type {
            case .movie: return SeerrMediaType.movie.rawValue
            case .series: return SeerrMediaType.tv.rawValue
            default: return nil
            }
        }

        var jellyfinTmdbKeys: Set<String> = []
        var jellyfinTitleYears: Set<String> = []
        for item in jellyfin {
            guard let type = seerrType(item.type) else { continue }
            if let tmdb = item.tmdbID { jellyfinTmdbKeys.insert("\(type)-\(tmdb)") }
            jellyfinTitleYears.insert("\(type)|" + titleYearKey(name: item.name, year: item.productionYear))
        }

        return seerr.filter { media in
            let type = media.mediaType.rawValue
            if jellyfinTmdbKeys.contains("\(type)-\(media.id)") { return false }
            let mediaYear = Int(media.displayYear ?? "")
            let key = "\(type)|" + titleYearKey(name: media.displayTitle, year: mediaYear)
            return !jellyfinTitleYears.contains(key)
        }
    }

    private func titleYearKey(name: String, year: Int?) -> String {
        let normalized = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        return "\(normalized)|\(year ?? 0)"
    }
}
