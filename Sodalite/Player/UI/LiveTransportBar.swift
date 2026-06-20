import SwiftUI

/// DVR transport for live playback: a scrubber over the engine's moving
/// seekable window, a live-edge marker, a position/LIVE label, and a
/// return-to-live indicator.
///
/// Live transport: a "Return to Live" pill focusable via Up from the
/// scrubber (PlayerHostController routes `.returnToLiveButton` Select to
/// returnToLiveEdge); scrubbing fully to the right edge still snaps to live
/// too (commitLiveScrub at >= 0.99). Audio/subtitle/speed chips for live are
/// a separate follow-up.
struct LiveTransportBar: View {
    @Bindable var viewModel: PlayerViewModel

    /// The return-to-live pill currently holds remote focus.
    private var returnToLiveFocused: Bool {
        viewModel.controlsFocus == .returnToLiveButton
    }

    var body: some View {
        VStack(spacing: 16) {
            // Scrub preview: same frame card the VOD bar shows, fed from
            // the engine's DVR cache. Nil image keeps the bar exactly as
            // before (the bar already has its own position label).
            if viewModel.isScrubbing, let preview = viewModel.scrubPreview.previewImage {
                liveScrubPreviewArea(image: preview)
            }

            // Position label (left) + return-to-live pill + LIVE badge (right).
            HStack(spacing: 16) {
                Text(positionLabel)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                // Return-to-live pill. Focusable from the scrubber via Up
                // (controlsFocus == .returnToLiveButton); Select fires
                // returnToLiveEdge. Focused state fills tinted per the app's
                // focus convention; unfocused is a muted outline.
                if !viewModel.isAtLiveEdge {
                    Text("livetv.returnToLive")
                        .font(.caption.bold())
                        .foregroundStyle(returnToLiveFocused ? Color.black : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                returnToLiveFocused
                                    ? AnyShapeStyle(.tint)
                                    : AnyShapeStyle(.white.opacity(0.2))
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(.tint, lineWidth: returnToLiveFocused ? 0 : 2)
                        )
                        .scaleEffect(returnToLiveFocused ? 1.08 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: returnToLiveFocused)
                }

                liveBadge
            }

            scrubber
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isScrubbing)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAtLiveEdge)
    }

    // MARK: - Live Badge

    /// "LIVE" pill. Lit with the active tint at the edge, muted while the
    /// user is watching behind live.
    private var liveBadge: some View {
        Text("livetv.liveBadge")
            .font(.caption.bold())
            .foregroundStyle(viewModel.isAtLiveEdge ? Color.white : .white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(viewModel.isAtLiveEdge ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.12)))
            )
    }

    // MARK: - Scrub Preview

    private static let scrubCardWidth: CGFloat = 320

    /// Frame card tracking the scrub knob, mirroring TransportBar's
    /// scrubPreviewArea (clamped so the card never leaves the bar). Sizes to
    /// the frame's own aspect (SD 4:3 channels stay 4:3) instead of forcing
    /// 16:9.
    private func liveScrubPreviewArea(image: CGImage) -> some View {
        let cardHeight = TransportBar.previewImageHeight(for: image)
        return GeometryReader { geo in
            let width = geo.size.width
            let half = Self.scrubCardWidth / 2
            let knobX = max(0, min(width, width * CGFloat(viewModel.scrubProgress)))
            let clampedX = max(half, min(width - half, knobX))
            Image(decorative: image, scale: 1.0)
                .resizable()
                .frame(width: Self.scrubCardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                .position(x: clampedX, y: cardHeight / 2)
        }
        .frame(height: cardHeight)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let active = viewModel.isScrubbing
            let trackHeight: CGFloat = active ? 10 : 6
            let knobSize: CGFloat = active ? 22 : 14
            let knobX = max(0, min(width, width * liveProgress))

            ZStack(alignment: .leading) {
                // Unplayed window track, white for contrast regardless of
                // the user's accent color (matches TransportBar).
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)

                // Position within the window, tinted.
                Capsule()
                    .fill(.tint)
                    .frame(width: knobX, height: trackHeight)

                // Live-edge marker: a thin tinted tick pinned to the right
                // end of the window (the live edge).
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: trackHeight + 8)
                    .offset(x: width - 3)

                // Playhead knob, tinted (focused-fill-tinted convention).
                Circle()
                    .fill(.tint)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: knobX - knobSize / 2)
            }
            .animation(.easeInOut(duration: 0.2), value: active)
        }
        .frame(height: 22)
    }

    // MARK: - Derived

    /// Fraction of the seekable window the playhead currently sits at.
    /// While scrubbing this tracks the in-flight scrub; otherwise it maps
    /// the playhead across `liveSeekableRange`. Defaults to the right edge
    /// (full bar) when the window is not yet known, so the bar reads "at
    /// live" on first paint.
    private var liveProgress: CGFloat {
        if viewModel.isScrubbing { return CGFloat(viewModel.scrubProgress) }
        guard let range = viewModel.liveSeekableRange,
              range.upperBound > range.lowerBound else { return 1 }
        let span = range.upperBound - range.lowerBound
        let pos = viewModel.playbackTime - range.lowerBound
        return CGFloat(max(0, min(1, pos / span)))
    }

    /// "LIVE" at the edge, otherwise "-M:SS" behind live.
    private var positionLabel: String {
        if viewModel.isAtLiveEdge {
            return NSLocalizedString("livetv.liveBadge", comment: "Live edge label")
        }
        let behind = max(0, Int(viewModel.behindLiveSeconds))
        return String(format: "-%d:%02d", behind / 60, behind % 60)
    }
}
