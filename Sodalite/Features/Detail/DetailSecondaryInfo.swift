import SwiftUI

/// Navigation target for the person page, set after the async TMDB-id
/// resolution from a Jellyfin cast member (the id isn't known until the
/// person item is fetched, so the route can't be a plain Int binding).
struct PersonRoute: Identifiable, Hashable {
    let tmdbID: Int
    let name: String
    var id: Int { tmdbID }
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

/// Tagline, crew (director / writer), and studios for a Jellyfin item.
/// Renders nothing when all are absent. Inserted into the detail glass
/// panels below the genres line.
struct DetailSecondaryInfo: View {
    let item: JellyfinItem

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
        (Text(labelKey).fontWeight(.semibold)
            + Text(verbatim: ": \(names.prefix(3).joined(separator: ", "))"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
