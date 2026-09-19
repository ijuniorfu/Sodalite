import SwiftUI

/// What the iOS player shows on this device while the picture plays somewhere else (Sodalite#156):
/// the artwork, what is running, and where it is running.
///
/// Opaque on purpose. AVKit draws its own external-playback placeholder on the layer underneath, and
/// covering it here is what keeps the screen from carrying two answers to the same question. The
/// alternative, turning `showsPlaybackControls` off, is not available: AVKit's internal Now Playing
/// session hangs off it, together with AirPods auto-detect and the synchronized Atmos path.
struct ExternalPlaybackBackdrop: View {
    let destination: ExternalPlaybackDestination
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let tintColor: Color

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isPad: Bool { hSizeClass == .regular }
    private var posterHeight: CGFloat { isPad ? 320 : 200 }

    var body: some View {
        ZStack {
            Color.black
            // The same artwork, blurred out into a wash. Nothing is readable in it, it only keeps the
            // screen from being a black rectangle with a card floating on it.
            if let artworkURL {
                AsyncCachedImage(url: artworkURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 60)
                        .overlay(Color.Theme.scrimHeavy)
                } placeholder: {
                    Color.clear
                }
            }

            VStack(spacing: isPad ? 28 : 20) {
                poster
                VStack(spacing: 6) {
                    Text(title)
                        .font(isPad ? .title2.weight(.semibold) : .headline)
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(isPad ? .body : .subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)

                destinationLabel
            }
            .padding(.horizontal, 32)
        }
        .ignoresSafeArea()
        // Display only: the gesture catcher underneath keeps the taps, the transport above keeps its own.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var poster: some View {
        if let artworkURL {
            AsyncCachedImage(url: artworkURL) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                Color.Theme.surfaceElevated
                    .aspectRatio(2 / 3, contentMode: .fit)
            }
            .frame(maxHeight: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.Theme.hairline)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
    }

    private var destinationLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.headline)
            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tintColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.Theme.restFillStrong))
    }

    private var glyph: String {
        switch destination {
        case .airPlay: return "airplayvideo"
        case .externalDisplay: return "tv"
        }
    }

    private var label: String {
        switch destination {
        case .airPlay(let name?):
            return String(format: String(localized: "player.externalPlayback.receiver",
                                         defaultValue: "Playing on %@"), name)
        case .airPlay:
            return String(localized: "player.externalPlayback.airplay", defaultValue: "Playing via AirPlay")
        case .externalDisplay:
            return String(localized: "player.externalPlayback.display",
                          defaultValue: "Playing on an external display")
        }
    }
}
