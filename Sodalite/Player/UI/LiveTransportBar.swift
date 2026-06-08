import SwiftUI

/// DVR transport for live playback: a scrubber over the engine's moving
/// seekable window, a live-edge marker, a position/LIVE label, and a
/// return-to-live indicator.
///
/// Live transport v1: the return-to-live action ships via scrubbing to the
/// right edge (commitLiveScrub snaps to the edge at >= 0.99). A dedicated
/// focusable "Return to Live" button wired into PlayerHostController's
/// controlsFocus state machine, and audio/subtitle/speed chips for live,
/// are on-device follow-ups.
struct LiveTransportBar: View {
    @Bindable var viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Position label (left) + return-to-live pill + LIVE badge (right).
            HStack(spacing: 16) {
                Text(positionLabel)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                // Informational return-to-live pill. The action itself is
                // reached by scrubbing fully to the right edge (see
                // commitLiveScrub); a dedicated focusable button is a v1
                // follow-up.
                if !viewModel.isAtLiveEdge {
                    Text("livetv.returnToLive")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(.white.opacity(0.2))
                        )
                        .overlay(
                            Capsule().strokeBorder(.tint, lineWidth: 2)
                        )
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
