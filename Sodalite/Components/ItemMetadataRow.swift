import SwiftUI

/// Shared metadata display row: year · runtime · rating badge · ★ score · optional extras
///
/// Separators sit BETWEEN the segments that survived, not in front of each one. Written the other
/// way the row grew a leading dot as soon as everything ahead of a segment dropped out, which the
/// rating switches (Sodalite#127) turn from a rarity into an everyday case.
struct ItemMetadataRow: View {
    let item: JellyfinItem
    var showRuntime: Bool = true
    /// Segments appended after the built-in ones. A list rather than a closure so a caller with
    /// nothing to add adds nothing: a closure handing back an EmptyView is still a segment, and the
    /// row put a separator in front of it, leaving the line ending on a dot with nothing behind it.
    var extras: [AnyView] = []
    /// Segments that carry their own border, appended last and with NO separator in front of the
    /// run. The format pills are the case: they are boxes with edges, the age rating beside them is
    /// another, and a dot between two bordered things lands hard against the first edge instead of
    /// standing between two words (Sodalite#146 round 3). Inside the run `FormatBadgeRow` already
    /// separates by spacing for the same reason.
    var badges: [AnyView] = []

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 { separator }
                segment
            }
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                badge
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var segments: [AnyView] {
        var out: [AnyView] = []

        if let year = item.productionYear {
            out.append(AnyView(Text(String(year))))
        }

        // `> 0` and not just non-nil: a file the server could not probe reports RunTimeTicks 0, and
        // "0 Min." is a measurement nobody made (Sodalite#146 round 2, seen on a test file).
        if showRuntime, let runtime = item.runTimeTicks, runtime > 0 {
            out.append(AnyView(Text(runtime.ticksToDisplay)))
        }

        if let rating = item.officialRating {
            out.append(AnyView(
                Text(rating)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.5), lineWidth: 1)
                    )
            ))
        }

        if let score = item.communityRating,
           dependencies.appearancePreferences.showCommunityRating {
            out.append(AnyView(
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(String(format: "%.1f", score))
                }
            ))
        }

        // RT critic score (needs a provider filling CriticRating, e.g. OMDb); fresh/rotten split at 60, jellyfin-web badge artwork.
        if let critic = item.criticRating,
           dependencies.appearancePreferences.showCriticRating {
            out.append(AnyView(
                HStack(spacing: 5) {
                    Image(critic >= 60 ? "RTFresh" : "RTRotten")
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 20)
                    Text(verbatim: "\(Int(critic)) %")
                }
            ))
        }

        out.append(contentsOf: extras)

        return out
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}
