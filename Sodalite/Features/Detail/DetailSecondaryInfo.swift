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

/// Two full-width, baseline-aligned info rows for the detail glass
/// panels: the caller's metadata line pairs with the tagline in row
/// one, the genres line with the studios line in row two, so the
/// left and right columns sit level instead of drifting apart as two
/// independently-spaced stacks (Sodalite#15 round 6 follow-up). The
/// left cells take layout priority and never truncate in favor of the
/// right; the right cells get the leftover width, trailing-anchored,
/// and truncate first. While the full-detail fetch is in flight the
/// right cells hold skeleton bars so the panel doesn't grow when
/// tagline / studios land. Director and writer are deliberately
/// absent: they already appear in the cast row below, and they
/// squeezed the studios line out of its width.
struct DetailInfoRows<LeftPrimary: View, LeftSecondary: View>: View {
    let item: JellyfinItem
    let hasFullDetail: Bool
    /// Whether the leftSecondary builder produces anything (the views
    /// know: it's the genres line). Gates the second row so a panel
    /// with neither genres nor a second right-side line doesn't carry
    /// an invisible row's worth of spacing (episode panel).
    var hasLeftSecondary: Bool = true
    @ViewBuilder let leftPrimary: () -> LeftPrimary
    @ViewBuilder let leftSecondary: () -> LeftSecondary

    /// Whether there is any tagline / studio info to show.
    static func hasContent(_ item: JellyfinItem) -> Bool {
        let hasStudios = !(item.studios?.isEmpty ?? true)
        let hasTagline = !(item.taglines?.first?.isEmpty ?? true)
        return hasTagline || hasStudios
    }

    var body: some View {
        let tagline = item.taglines?.first
        let hasTagline = !(tagline?.isEmpty ?? true)
        let studios = studiosLine(item.studios?.map(\.name) ?? [])
        // Skeleton bars only while the right side can still gain
        // content: once the detail fetch settles empty, the rows
        // collapse to their left cells.
        let showPlaceholders = !hasFullDetail && !Self.hasContent(item)
        // The right column fills top-down: without a tagline the
        // studios move up into row one, level with the metadata line,
        // instead of dangling alone a row below it.
        let studiosInRowOne = !hasTagline && studios != nil

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                leftPrimary()
                    .layoutPriority(1)
                Spacer(minLength: 24)
                if hasTagline, let tagline {
                    Text(tagline)
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let studios {
                    styled(studios)
                } else if showPlaceholders {
                    placeholderBar(width: 220)
                }
            }
            if hasLeftSecondary || (hasTagline && studios != nil) || showPlaceholders {
                HStack(alignment: .firstTextBaseline) {
                    leftSecondary()
                        .layoutPriority(1)
                    Spacer(minLength: 24)
                    if !studiosInRowOne, let studios {
                        styled(studios)
                    } else if showPlaceholders {
                        placeholderBar(width: 140)
                    }
                }
            }
        }
    }

    private func styled(_ line: Text) -> some View {
        line
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func placeholderBar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.Theme.surface)
            .frame(width: width, height: 14)
    }

    private func studiosLine(_ studios: [String]) -> Text? {
        guard !studios.isEmpty else { return nil }
        // Text interpolation instead of the tvOS-26-deprecated `Text + Text`
        // concatenation; both segments keep their own styling.
        return Text("\(Text("detail.studios").fontWeight(.semibold))\(Text(verbatim: ": \(studios.prefix(3).joined(separator: ", "))"))")
    }
}
