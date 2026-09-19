import SwiftUI
import UIKit

#if os(iOS)

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

    var body: some View {
        // Absolute-geometry mount, the same pattern and the same reason as `controlsOverlay`: inside
        // AVKit the SwiftUI hosting pipeline serves corrupt safe-area insets in portrait, so the
        // layout is measured from UIKit truth and pinned back over the real screen.
        GeometryReader { geo in
            let allotted = geo.frame(in: .global)
            let (screen, _) = PlayerOverlayView.windowGeometry(fallback: geo.size)
            let band = ExternalPlaybackPresentation.contentBand(screenHeight: screen.height)
            ZStack(alignment: .top) {
                background(screen: screen)
                content(bandHeight: band.height)
                    .frame(width: screen.width, height: band.height)
                    // Offset, not `.position`: position resolves against the stack's own bounds, and
                    // anything in the stack that reports a size larger than the proposal moves that
                    // origin with it. Offset is drawn, not laid out, so it cannot be moved that way.
                    .offset(y: band.minY)
            }
            .frame(width: screen.width, height: screen.height)
            .position(x: screen.width / 2 - allotted.minX, y: screen.height / 2 - allotted.minY)
        }
        // Display only: the gesture catcher underneath keeps the taps, the transport above its own.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func background(screen: CGRect) -> some View {
        Color.black
        // The same artwork, blurred out into a wash. Nothing is readable in it, it only keeps the
        // screen from being a black rectangle with a card floating on it.
        //
        // Sized and clipped to the screen rather than left to fill freely: `scaledToFill` reports the
        // OVERFLOWING size, which grows the stack around it past the frame, and everything else in
        // the stack is then laid out against that larger box. Unclipped, the portrait block sat 109pt
        // left of centre and the landscape one 295pt above the top edge.
        if let artworkURL {
            AsyncCachedImage(url: artworkURL) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: screen.width, height: screen.height)
                    .clipped()
                    .blur(radius: 60)
                    .overlay(Color.Theme.scrimHeavy)
            } placeholder: {
                Color.clear
            }
        }
    }

    private func content(bandHeight: CGFloat) -> some View {
        let short = bandHeight < ExternalPlaybackPresentation.shortBandHeight
        return VStack(spacing: short ? 12 : 20) {
            poster(height: ExternalPlaybackPresentation.posterHeight(bandHeight: bandHeight, isPad: isPad))
            VStack(spacing: short ? 2 : 6) {
                Text(title)
                    .font(short ? .subheadline.weight(.semibold)
                                : (isPad ? .title2.weight(.semibold) : .headline))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(short ? .footnote : (isPad ? .body : .subheadline))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(1)

            destinationLabel(short: short)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func poster(height: CGFloat) -> some View {
        if let artworkURL {
            AsyncCachedImage(url: artworkURL) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                Color.Theme.surfaceElevated
                    .aspectRatio(2 / 3, contentMode: .fit)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.Theme.hairline)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
    }

    private func destinationLabel(short: Bool) -> some View {
        HStack(spacing: short ? 8 : 10) {
            Image(systemName: glyph)
                .font(short ? .subheadline : .headline)
            Text(label)
                .font(short ? .footnote.weight(.medium) : .subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tintColor)
        .padding(.horizontal, short ? 12 : 16)
        .padding(.vertical, short ? 7 : 10)
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
#endif
