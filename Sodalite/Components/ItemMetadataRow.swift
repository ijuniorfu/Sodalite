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

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 { separator }
                segment
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

        if showRuntime, let runtime = item.runTimeTicks {
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
