import Foundation
import Observation

/// Source-neutral person header. TMDB supplies the richer version through Seerr, Jellyfin's own
/// person item supplies the reduced one when Seerr is absent or unreachable (Sodalite#57).
struct PersonProfile: Equatable, Sendable {
    var name: String
    var biography: String?
    var knownForDepartment: String?
    /// TMDB profile path, set only on the Seerr-sourced profile.
    var tmdbProfilePath: String?
    /// Jellyfin person item and its primary image tag, set only on the Jellyfin-sourced profile.
    var jellyfinPersonID: String?
    var jellyfinImageTag: String?

    init(seerr detail: SeerrPersonDetail) {
        name = detail.name
        biography = detail.biography
        knownForDepartment = detail.knownForDepartment
        tmdbProfilePath = detail.profilePath
    }

    init(jellyfin item: JellyfinItem) {
        name = item.name
        biography = item.overview
        jellyfinPersonID = item.id
        jellyfinImageTag = item.imageTags?.primary
    }
}

/// Loading and failure policy for the person page. The page has two independent halves, the library
/// rows from Jellyfin and the profile plus filmography from Seerr, and it stays useful when either
/// one is missing: with no Seerr it degrades to a Jellyfin-only page instead of an error screen.
@MainActor
@Observable
final class PersonDetailViewModel {
    private(set) var profile: PersonProfile?
    private(set) var filmography: [SeerrMedia] = []
    private(set) var library: PersonLibraryResults = .empty
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    /// True once the page knows Seerr will not contribute, so the view can drop the filmography
    /// heading rather than claim the person has no titles.
    private(set) var filmographyUnavailable = false

    private let itemService: JellyfinItemServiceProtocol
    private let mediaService: SeerrMediaServiceProtocol
    private let isSeerrConnected: Bool
    private let userID: String?
    /// Kept so a retry does not pay for the id translation a second time.
    private var resolvedTMDBID: Int?

    init(
        itemService: JellyfinItemServiceProtocol,
        mediaService: SeerrMediaServiceProtocol,
        isSeerrConnected: Bool,
        userID: String?
    ) {
        self.itemService = itemService
        self.mediaService = mediaService
        self.isSeerrConnected = isSeerrConnected
        self.userID = userID
    }

    /// `tmdbID` from a Seerr-sourced entry point, `jellyfinPersonID` from a library cast row; the
    /// page is opened with whichever one the caller had and resolves the other side here.
    func load(tmdbID: Int?, jellyfinPersonID: String?, name: String) async {
        isLoading = true
        errorMessage = nil
        filmographyUnavailable = false
        defer { isLoading = false }

        // Both halves at once: the library rows never wait on Seerr, and a Seerr failure never
        // costs the rows.
        async let librarySide = loadLibrary(jellyfinPersonID: jellyfinPersonID, tmdbID: tmdbID, name: name)
        async let seerrSide = loadSeerr(tmdbID: tmdbID, jellyfinPersonID: jellyfinPersonID)

        let (libraryPersonID, results) = await librarySide
        let seerr = await seerrSide

        library = results

        switch seerr {
        case .loaded(let detail, let credits):
            profile = PersonProfile(seerr: detail)
            filmography = Self.computeFilmography(from: credits)
        case .unavailable(let reason):
            filmographyUnavailable = true
            // No TMDB half: Jellyfin's own person item still carries a name, a photo and a bio.
            if let libraryPersonID,
               let userID,
               let item = try? await itemService.getItemDetail(userID: userID, itemID: libraryPersonID) {
                profile = PersonProfile(jellyfin: item)
            }
            if profile == nil && library.isEmpty {
                errorMessage = reason
            }
        }
    }

    private enum SeerrOutcome {
        case loaded(SeerrPersonDetail, SeerrPersonCredits?)
        /// Carries the message to show if the Jellyfin side turns up nothing either.
        case unavailable(String)
    }

    private func loadSeerr(tmdbID: Int?, jellyfinPersonID: String?) async -> SeerrOutcome {
        guard isSeerrConnected else {
            return .unavailable(String(
                localized: "person.seerrNotConnected",
                defaultValue: "Seerr is not connected. Connect Seerr in Settings to view this page."
            ))
        }
        guard let id = await personTMDBID(tmdbID: tmdbID, jellyfinPersonID: jellyfinPersonID) else {
            return .unavailable(String(
                localized: "person.noTmdbID",
                defaultValue: "This cast member has no TMDB id on the server, so there is no person page to show."
            ))
        }
        do {
            async let detail = mediaService.personDetail(tmdbID: id)
            async let credits = mediaService.personCredits(tmdbID: id)
            return .loaded(try await detail, try? await credits)
        } catch {
            return .unavailable(ErrorText.user(for: error))
        }
    }

    private func loadLibrary(
        jellyfinPersonID: String?,
        tmdbID: Int?,
        name: String
    ) async -> (String?, PersonLibraryResults) {
        guard let userID else { return (nil, .empty) }
        guard let personID = await PersonLibrary.resolvePersonID(
            itemService: itemService,
            userID: userID,
            jellyfinPersonID: jellyfinPersonID,
            name: name,
            tmdbID: tmdbID ?? resolvedTMDBID
        ) else { return (nil, .empty) }
        let results = await PersonLibrary.load(
            itemService: itemService, userID: userID, personID: personID
        )
        return (personID, results)
    }

    /// Jellyfin's item response carries no provider ids for cast, so a Jellyfin-sourced person costs
    /// one lookup to reach TMDB. Runs inside `load()` so the spinner covers it.
    private func personTMDBID(tmdbID: Int?, jellyfinPersonID: String?) async -> Int? {
        if let tmdbID { return tmdbID }
        if let resolvedTMDBID { return resolvedTMDBID }
        guard let jellyfinPersonID, let userID else { return nil }
        let person = try? await itemService.getItemDetail(userID: userID, itemID: jellyfinPersonID)
        resolvedTMDBID = person?.tmdbID
        return resolvedTMDBID
    }

    /// cast + crew, deduped by stableKey, poster-only, newest first. Computed once when credits land
    /// rather than re-deduped and re-sorted on every body pass.
    static func computeFilmography(from credits: SeerrPersonCredits?) -> [SeerrMedia] {
        let all = (credits?.cast ?? []) + (credits?.crew ?? [])
        var seen = Set<String>()
        let deduped = all.filter { seen.insert($0.stableKey).inserted }
        return deduped
            .filter { $0.posterPath != nil }
            .sorted {
                ($0.releaseDate ?? $0.firstAirDate ?? "")
                    > ($1.releaseDate ?? $1.firstAirDate ?? "")
            }
    }
}
