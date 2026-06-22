import SwiftUI

/// Read-only episode preview card in the catalog series detail; no per-episode request action since Jellyseerr's smallest request unit is a whole season.
struct SeerrEpisodeCard: View {
    let episode: SeerrEpisode
    let isFocused: Bool

    private let width: CGFloat = 320
    private let imageHeight: CGFloat = 180
    // Reserves room for title + optional subtitle so cards stay equal height regardless of subtitle presence.
    private let captionHeight: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color(white: 0.1)
                    .frame(width: width, height: imageHeight)

                if let url = SeerrImageURL.backdrop(path: episode.stillPath, size: .w780) {
                    AsyncCachedImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholderArt
                    }
                    .frame(width: width, height: imageHeight)
                    .clipped()
                } else {
                    placeholderArt
                }

                // Episode-number chip, top-leading so it doesn't overlap the still's centre.
                VStack {
                    HStack {
                        Text("\(episode.episodeNumber)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: width, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Focus border on the fixed-height still so it can't drift with caption-block size.
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 4)
                    .opacity(isFocused ? 1 : 0)
            )

            // Fixed-height caption block keeps cards equal total height (top-aligned in the row) with or without the subtitle.
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.name ?? "")
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: width, alignment: .leading)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, height: captionHeight, alignment: .topLeading)
        }
        .frame(width: width)
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 14, y: 6)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "tv")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
        }
        .frame(width: width, height: imageHeight)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let date = episode.airDate, date.count >= 4 {
            parts.append(String(date.prefix(4)))
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
