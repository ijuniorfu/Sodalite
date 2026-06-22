import SwiftUI

/// Shared metadata display row: year · runtime · rating badge · ★ score · optional extras
struct ItemMetadataRow: View {
    let item: JellyfinItem
    var showRuntime: Bool = true
    var extraContent: (() -> AnyView)?

    var body: some View {
        HStack(spacing: 12) {
            if let year = item.productionYear {
                Text(String(year))
            }

            if showRuntime, let runtime = item.runTimeTicks {
                separator
                Text(runtime.ticksToDisplay)
            }

            if let rating = item.officialRating {
                separator
                Text(rating)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.5), lineWidth: 1)
                    )
            }

            if let score = item.communityRating {
                separator
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(String(format: "%.1f", score))
                }
            }

            // RT critic score (needs a provider filling CriticRating, e.g. OMDb); fresh/rotten split at 60, jellyfin-web badge artwork.
            if let critic = item.criticRating {
                separator
                HStack(spacing: 5) {
                    Image(critic >= 60 ? "RTFresh" : "RTRotten")
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 20)
                    Text(verbatim: "\(Int(critic)) %")
                }
            }

            if let extra = extraContent {
                separator
                extra()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}
