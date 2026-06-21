import SwiftUI

/// Compact metadata line for the Seerr detail header: rating, runtime,
/// year, certification. Mirrors the Jellyfin `ItemMetadataRow` style.
/// Each segment is omitted when its value is nil.
struct SeerrMetadataRow: View {
    let rating: Double?
    let runtimeMinutes: Int?
    let year: String?
    let certification: String?
    /// Rotten Tomatoes critics score (0-100). Shown with the fresh/rotten
    /// badge, split at 60, matching the Jellyfin detail row.
    var rtCriticsScore: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 { separator }
                segment.view
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private struct Segment {
        let view: AnyView
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        if let rating, rating > 0 {
            out.append(Segment(view: AnyView(
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(String(format: "%.1f", rating))
                }
            )))
        }
        if let rtCriticsScore {
            out.append(Segment(view: AnyView(
                HStack(spacing: 5) {
                    Image(rtCriticsScore >= 60 ? "RTFresh" : "RTRotten")
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 18)
                    Text(verbatim: "\(rtCriticsScore) %")
                }
            )))
        }
        if let runtimeMinutes, runtimeMinutes > 0 {
            out.append(Segment(view: AnyView(Text(runtimeLabel(runtimeMinutes)))))
        }
        if let year {
            out.append(Segment(view: AnyView(Text(year))))
        }
        if let certification, !certification.isEmpty {
            out.append(Segment(view: AnyView(
                Text(certification)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.5), lineWidth: 1)
                    )
            )))
        }
        return out
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    /// "1h 47m" / "47m". Minutes-based (TMDB runtime is in minutes).
    private func runtimeLabel(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
