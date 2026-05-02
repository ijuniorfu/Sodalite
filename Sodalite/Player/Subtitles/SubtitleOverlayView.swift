import SwiftUI
import AetherEngine

/// Renders the subtitle cues active at the current playback time on top
/// of the video. Two body kinds:
///
/// - **Text** — a centered, semi-transparent black box with white text.
///   At most one text cue is active at a time in practice (FFmpeg's
///   text decoders merge same-time rects into one cue), but the layout
///   tolerates more.
/// - **Image** — a bitmap with normalised position (PGS / DVB / HDMV).
///   Multiple bitmap cues can overlap (signs/songs at the top while
///   dialogue stays at the bottom), so we render every active one.
struct SubtitleOverlayView: View {
    let cues: [SubtitleCue]
    let currentTime: Double

    var body: some View {
        GeometryReader { geo in
            // `Color.clear` fills the proposed size so the overlay
            // covers the same rect as the underlying video layer
            // (otherwise SwiftUI may collapse the ZStack to the
            // largest child's frame and the .offset math suddenly
            // anchors against a small box). `.overlay(alignment:
            // .topLeading)` makes (0, 0) of the inner views the
            // top-left corner of that rect, so subtitle absolute
            // positions become a straight `.offset(x: pixels, y:
            // pixels)` from there.
            Color.clear
                .overlay(alignment: .topLeading) {
                    ForEach(activeCues, id: \.id) { cue in
                        switch cue.body {
                        case .text(let text):
                            textOverlay(text, in: geo.size)
                        case .image(let image):
                            imageOverlay(image, in: geo.size)
                        }
                    }
                }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Text branch

    private func textOverlay(_ text: String, in size: CGSize) -> some View {
        // Pinned to the bottom-centre of the video rect with a
        // ~80pt safe-area gap. Width is capped so long lines wrap
        // with horizontal margins on either side.
        let maxWidth = max(0, size.width - 240)
        return Text(text)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: maxWidth)
            .frame(width: size.width, alignment: .center)
            .position(x: size.width / 2, y: size.height - 100)
            .transition(.opacity)
    }

    // MARK: - Image branch

    private func imageOverlay(_ image: SubtitleImage, in size: CGSize) -> some View {
        // Normalised position is in source-video coordinates. The
        // outer Color.clear fills the GeometryReader rect, the
        // overlay's alignment is .topLeading, so an .offset of
        // (x_pixels, y_pixels) from the top-left puts the image's
        // top-left corner at exactly (x_pixels, y_pixels) on the
        // video.
        let frameW = image.position.width * size.width
        let frameH = image.position.height * size.height
        let originX = image.position.minX * size.width
        let originY = image.position.minY * size.height

        return Image(decorative: image.cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: frameW, height: frameH)
            .offset(x: originX, y: originY)
    }

    // MARK: - Active-cue lookup

    /// Returns every cue whose time range contains `currentTime`.
    /// Cues are sorted by `startTime` (engine + sidecar both insert in
    /// order), so we binary-search for the first cue starting after
    /// now and walk back collecting any whose endTime hasn't passed.
    private var activeCues: [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].startTime > currentTime {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        var result: [SubtitleCue] = []
        var i = lo - 1
        while i >= 0, cues[i].startTime <= currentTime {
            if cues[i].endTime >= currentTime {
                result.append(cues[i])
            }
            i -= 1
        }
        return result.reversed()
    }
}
