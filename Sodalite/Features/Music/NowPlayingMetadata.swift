import SwiftUI

/// The three lines under (or beside) the Now Playing cover: context, track, artist.
///
/// Its own component because the sizes are a measurement, not a taste. A podcast episode title is
/// several times the length of a song title, and at the 720pt the centred column gives it the old
/// ramp asked for 1.98 lines and allowed exactly one, so every podcast arrived with an ellipsis
/// (Sodalite#110 round 3). `NowPlayingMetadataBudgetTests` hosts this view at that width and pins
/// the worst realistic string against the room the column has.
///
/// Which line leads changed with it. The album used to be the big bold line and the track the small
/// one under it, which reads as a heading for the queue beside it but leaves the thing actually
/// playing as the least prominent text on a screen whose whole subject is that track. The show or
/// album is a kicker now, Apple Podcasts' arrangement, and the track carries the size and the
/// foreground colour.
struct NowPlayingMetadata: View {
    /// Album or show, the heading the queue was started from.
    let context: String?
    /// Track or episode.
    let title: String
    /// Track artists, or the album artist.
    let artist: String?
    let centered: Bool

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: NowPlayingMetrics.metadataSpacing) {
            if let context, !context.isEmpty {
                Text(context)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
            } else {
                // Nothing above it to be a kicker for, so the track keeps the heading size it had.
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(2)
            }

            // One line on purpose. Two of the three lines may wrap inside the budget, not all three,
            // and of the three this is the one a viewer is least likely to be reading.
            if let artist, !artist.isEmpty {
                Text(artist)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}
