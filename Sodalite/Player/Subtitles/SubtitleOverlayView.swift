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
            ZStack {
                ForEach(activeCues, id: \.id) { cue in
                    switch cue.body {
                    case .text(let text):
                        textOverlay(text)
                    case .image(let image):
                        imageOverlay(image, in: geo.size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Text branch

    private func textOverlay(_ text: String) -> some View {
        // `.frame(maxWidth: .infinity)` is critical here — without it
        // the VStack collapses to the text's content width and the
        // ZStack centers that small column at screen-center, which
        // visually keeps the text near the left edge of a wide frame
        // instead of at the centre.
        VStack {
            Spacer()
            Text(text)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 120)
                .padding(.bottom, 80)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Image branch

    private func imageOverlay(_ image: SubtitleImage, in size: CGSize) -> some View {
        // Normalised position is in source-video coordinates; the
        // host view fills the screen so we just scale by the
        // available size. ZStack centers items by default — push
        // the bitmap to its top-leading corner with a manual offset.
        let frameW = image.position.width * size.width
        let frameH = image.position.height * size.height
        let offX = image.position.minX * size.width + frameW / 2
            - size.width / 2
        let offY = image.position.minY * size.height + frameH / 2
            - size.height / 2

        return Image(decorative: image.cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: frameW, height: frameH)
            .offset(x: offX, y: offY)
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
