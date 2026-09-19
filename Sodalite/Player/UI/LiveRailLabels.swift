import SwiftUI
import UIKit

/// Sodalite#104: what the live rail says in words, for whichever transport is on screen.
///
/// The two ends of the block, the wall clock of the frame on screen tracking the knob between them,
/// and the programme that follows. One implementation, because the first round of this issue shipped
/// with the tvOS view holding its own copy of the rail arithmetic and the copy drifted: the badge and
/// the knob ended up answering different questions about the same edge. The two transports differ in
/// type scale and in nothing else, so that is the only thing they pass in.
struct LiveRailLabels: View {
    let viewModel: PlayerViewModel
    var font: Font = defaultFont
    var rowHeight: CGFloat = defaultRowHeight

    /// `.callout` on the ten-foot bar, `.caption` on the phone, matching what each transport already
    /// gives the two slots this row replaces. The pair lives here rather than at the call sites so
    /// the row and its height cannot be set from two different readings of the same platform.
    static var defaultFont: Font {
        #if os(tvOS)
        .callout
        #else
        .caption
        #endif
    }

    /// As tall as the tallest thing it draws, which is not a free number, and on tvOS not a number
    /// this file gets to decide either.
    ///
    /// This row was 30 pt on both platforms, a height measured for the phone's `.caption`. tvOS
    /// `.callout` is 31 pt with a 36.99 pt line, so on the television the clock sat 3.5 pt above its
    /// own row and the press readout, a two-line column of 66 pt, sat 18 pt above it: that is where
    /// the gap to the scrubber went, and the knob grows to 22 pt at exactly the moment the readout
    /// exists.
    ///
    /// The tallest thing is the skip glyph and the system owns its height, so the row asks
    /// (`SeekReadoutMetrics`) rather than remembers. On tvOS 26.5 the answer is 40 to the point,
    /// which is what this replaced.
    static var defaultRowHeight: CGFloat {
        #if os(tvOS)
        tallestDrawnHeight
        #else
        20
        #endif
    }

    #if os(tvOS)
    /// The tallest glyph this rail can put beside the clock, against its own text line, measured once.
    private static let tallestDrawnHeight = SeekReadoutMetrics.rowHeight(
        symbol: UIImage.SymbolConfiguration(textStyle: .callout),
        lineHeight: UIFont.preferredFont(forTextStyle: .callout).lineHeight)
    #endif

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Text(PlayerViewModel.clockLabel(for: viewModel.liveRailBlock.start))
                    Spacer(minLength: 0)
                    Text(PlayerViewModel.clockLabel(for: viewModel.liveRailBlock.end))
                }
                .font(font)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))

                // Hidden rather than pushed aside near the ends: there it would say what the end label
                // beside it already says, and a clock sliding out from under its own knob reads worse
                // than one that steps aside. The margin is a share of the width, so the phone hides it
                // sooner than the television does, which is the right answer on a 350pt rail.
                if let playheadClock, !clockCollides(width: width) {
                    HStack(spacing: 8) {
                        if let readout = viewModel.seekReadout, readout.direction == -1 {
                            SeekReadoutView(readout: readout, font: font)
                        }
                        Text(playheadClock)
                            .font(font)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        if let readout = viewModel.seekReadout, readout.direction == 1 {
                            SeekReadoutView(readout: readout, font: font)
                        }
                    }
                    .fixedSize()
                    .position(x: knobX(width), y: rowHeight / 2)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func knobX(_ width: CGFloat) -> CGFloat {
        max(0, min(width, width * CGFloat(viewModel.liveDisplayedProgress)))
    }

    private func clockCollides(width: CGFloat) -> Bool {
        let margin = max(60, width * 0.22)
        let x = knobX(width)
        return x < margin || x > width - margin
    }

    /// The wall clock of the frame on screen, or of the position a scrub is pointing at.
    private var playheadClock: String? {
        let block = viewModel.liveRailBlock
        guard block.seconds > 0 else { return nil }
        return PlayerViewModel.clockLabel(for: block.wallClock(at: viewModel.liveDisplayedProgress))
    }

}

/// Sodalite#104: what follows the block, under the rail that marks its end, which is the thing it
/// counts toward.
struct LiveNextUpLine: View {
    let viewModel: PlayerViewModel
    var font: Font = LiveRailLabels.defaultFont

    var body: some View {
        if let next = viewModel.liveNextProgram, let starts = next.startDate {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(Self.text(name: next.name, startsIn: starts.timeIntervalSince(Date())))
                    .font(font)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
    }

    /// "In 101 minutes: The OT", or the name alone once the countdown would read as zero.
    static func text(name: String, startsIn seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 1 else {
            return String(format: String(localized: "livetv.nextUp.now",
                                         defaultValue: "Next: %@"), name)
        }
        let inWords = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return String(format: String(localized: "livetv.nextUp",
                                     defaultValue: "In %1$@: %2$@"), inWords, name)
    }
}

/// Sodalite#104: whether the picture is live is a STATUS, so the badge says it in the palette's
/// status colour and not in the accent.
///
/// It cannot be focused and it cannot be pressed, and it was filled with the exact colour every
/// focusable control in its row wears; on the phone it sat beside the Return to Live BUTTON in the
/// same tint, one of the two pressable and one not. The chip keeps the tint precisely so that the two
/// stop looking alike.
///
/// The colour moves to the WORD rather than the fill, which is both where the palette puts `success`
/// everywhere else and the only legible way round: a white label on a system-green fill measures
/// 2.0:1, under any reading of large text, while the green word on the rest fill measures 8.2:1 on
/// black and 3.4:1 against the brightest picture the control scrim lets through. The pill itself
/// therefore never changes, which is the honest drawing too, since what changes is the word.
struct LiveBadge: View {
    let isAtLiveEdge: Bool
    var font: Font = LiveRailLabels.defaultFont
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 8

    var body: some View {
        Text("livetv.liveBadge")
            .font(font.bold())
            .foregroundStyle(isAtLiveEdge ? AnyShapeStyle(Color.Theme.success)
                                          : AnyShapeStyle(Color.white.opacity(0.5)))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Capsule().fill(Color.Theme.restFillStrong))
    }
}
