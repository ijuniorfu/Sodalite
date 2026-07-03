import SwiftUI

/// Person-page navigation target, set after async TMDB-id resolution (the id isn't known until the person item is fetched).
struct PersonRoute: Identifiable, Hashable {
    let tmdbID: Int
    let name: String
    var id: Int { tmdbID }
}

/// Resolve a cast member to a TMDB person id and hand the route to the caller; inert when the server has no TMDB id. Shared by Movie/SeriesDetailView cast-row taps.
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

/// Map Jellyfin cast people to CastMember (Jellyfin person id stored, TMDB personID nil until tap-resolved). Capped at 15.
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

extension View {
    /// Wraps a crowded action-button row in a horizontal scroll on compact width so it can't
    /// clip the prominent Play button off-screen. tvOS/iPad (regular) keep the static row.
    @ViewBuilder
    func compactScrollableRow(_ sizeClass: UserInterfaceSizeClass?) -> some View {
        if sizeClass == .compact {
            ScrollView(.horizontal, showsIndicators: false) { self }
        } else {
            self
        }
    }
}

/// Two full-width baseline-aligned rows for the detail glass panels: metadata + tagline (row one), genres + studios (row two), so left/right columns sit level instead of drifting as two independent stacks (Sodalite#15 round 6 follow-up). Left cells take layout priority and never truncate; right cells get leftover width, trailing-anchored, truncate first. While detail is in flight the right cells hold skeleton bars so the panel doesn't grow when tagline/studios land. Director/writer deliberately absent (already in the cast row, and they squeezed studios out of its width).
struct DetailInfoRows<LeftPrimary: View, LeftSecondary: View>: View {
    let item: JellyfinItem
    let hasFullDetail: Bool
    /// Whether leftSecondary (the genres line) produces anything; gates the second row so an episode panel with no genres carries no invisible row spacing.
    var hasLeftSecondary: Bool = true
    /// Genres still unknown (slim row item, detail fetch in flight): reserve the genre line's height so the panel doesn't grow and push the buttons down when it lands. The skeleton bars below only cover the right column.
    var leftSecondaryPending: Bool = false
    @ViewBuilder let leftPrimary: () -> LeftPrimary
    @ViewBuilder let leftSecondary: () -> LeftSecondary

    @Environment(\.horizontalSizeClass) private var hSizeClass

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

        if hSizeClass == .compact {
            // Phone: a single leading column with the metadata in a no-wrap horizontal scroll, so
            // values never break mid-token ("2 Std. 32 Min.") or stack vertically in the tight panel.
            VStack(alignment: .leading, spacing: 6) {
                leftPrimary()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if hasLeftSecondary {
                    leftSecondary()
                        .lineLimit(1)
                } else if leftSecondaryPending {
                    genreLinePlaceholder
                }
                if let studios {
                    styled(studios)
                } else if showPlaceholders {
                    placeholderBar(width: 140)
                }
            }
        } else {
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
                if hasLeftSecondary || leftSecondaryPending || (hasTagline && studios != nil) || showPlaceholders {
                    HStack(alignment: .firstTextBaseline) {
                        leftSecondary()
                            .layoutPriority(1)
                        if !hasLeftSecondary && leftSecondaryPending {
                            genreLinePlaceholder
                        }
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
    }

    private func styled(_ line: Text) -> some View {
        line
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Skeleton for the genre line itself: a blank subheadline Text supplies the exact line height and baseline the real genre Text will have, the bar just draws over it.
    private var genreLinePlaceholder: some View {
        Text(verbatim: " ")
            .font(.subheadline)
            .lineLimit(1)
            .frame(width: 180, alignment: .leading)
            .overlay(alignment: .leading) { placeholderBar(width: 180) }
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
