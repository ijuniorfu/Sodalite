import SwiftUI

/// Navigation target for the person page, set after the async TMDB-id
/// resolution from a Jellyfin cast member (the id isn't known until the
/// person item is fetched, so the route can't be a plain Int binding).
struct PersonRoute: Identifiable, Hashable {
    let tmdbID: Int
    let name: String
    var id: Int { tmdbID }
}

/// Resolve a Jellyfin cast member to a TMDB person id, then hand the
/// person route to the caller for navigation. Inert when the server
/// has no TMDB id for them. Shared by MovieDetailView and
/// SeriesDetailView's cast-row tap handlers.
func resolvePersonRoute(
    for member: CastMember,
    userID: String?,
    itemService: JellyfinItemServiceProtocol,
    onResolved: @escaping (PersonRoute) -> Void
) {
    guard let jid = member.jellyfinPersonID,
          let userID else { return }
    Task {
        if let person = try? await itemService.getItemDetail(
               userID: userID, itemID: jid
           ),
           let tmdb = person.tmdbID {
            onResolved(PersonRoute(tmdbID: tmdb, name: member.name))
        }
    }
}

/// Maps Jellyfin cast people to the shared `CastMember` model. Stores
/// the Jellyfin person id (resolved to a TMDB id on tap); `personID`
/// (TMDB) stays nil for Jellyfin-sourced members. Capped at 15.
func jellyfinCastMembers(
    from people: [PersonInfo],
    imageService: JellyfinImageService
) -> [CastMember] {
    people.prefix(15).map { person in
        CastMember(
            id: person.id,
            name: person.name,
            role: person.role,
            imageURL: imageService.personImageURL(
                personID: person.id,
                tag: person.primaryImageTag
            ),
            personID: nil,
            jellyfinPersonID: person.id
        )
    }
}

/// Two skeleton lines standing in for DetailSecondaryInfo while the
/// full-detail fetch is in flight, so the glass panel doesn't grow
/// when tagline / crew / studios land (Sodalite#15). Callers gate on
/// `DetailViewModel.hasFullDetail`.
struct DetailSecondaryInfoPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.Theme.surface)
                .frame(width: 220, height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.Theme.surface)
                .frame(width: 140, height: 14)
        }
    }
}

/// Tagline, crew (director / writer), and studios for a Jellyfin item.
/// Renders nothing when all are absent. Inserted into the detail glass
/// panels below the genres line.
struct DetailSecondaryInfo: View {
    let item: JellyfinItem

    /// Whether there is any tagline / crew / studio info to show.
    static func hasContent(_ item: JellyfinItem) -> Bool {
        let directors = (item.people ?? []).contains { $0.type == "Director" }
        let writers = (item.people ?? []).contains { $0.type == "Writer" }
        let hasStudios = !(item.studios?.isEmpty ?? true)
        let hasTagline = !(item.taglines?.first?.isEmpty ?? true)
        return hasTagline || directors || writers || hasStudios
    }

    var body: some View {
        let directors = names(ofType: "Director")
        let writers = names(ofType: "Writer")
        let studios = item.studios?.map(\.name) ?? []
        let tagline = item.taglines?.first

        if hasContent(tagline: tagline, directors: directors, writers: writers, studios: studios) {
            VStack(alignment: .leading, spacing: 6) {
                if let tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                }
                if !directors.isEmpty {
                    creditLine(labelKey: "detail.director", names: directors)
                }
                if !writers.isEmpty {
                    creditLine(labelKey: "detail.writer", names: writers)
                }
                if !studios.isEmpty {
                    creditLine(labelKey: "detail.studios", names: studios)
                }
            }
        }
    }

    private func hasContent(tagline: String?, directors: [String], writers: [String], studios: [String]) -> Bool {
        (tagline.map { !$0.isEmpty } ?? false)
            || !directors.isEmpty
            || !writers.isEmpty
            || !studios.isEmpty
    }

    private func names(ofType type: String) -> [String] {
        (item.people ?? [])
            .filter { $0.type == type }
            .map(\.name)
    }

    private func creditLine(labelKey: LocalizedStringKey, names: [String]) -> some View {
        // Text interpolation instead of the tvOS-26-deprecated `Text + Text`
        // concatenation; both segments keep their own styling.
        Text("\(Text(labelKey).fontWeight(.semibold))\(Text(verbatim: ": \(names.prefix(3).joined(separator: ", "))"))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}
