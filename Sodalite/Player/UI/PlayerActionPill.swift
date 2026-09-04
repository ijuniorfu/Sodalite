import SwiftUI

/// Geometry of the player's two floating action pills: the Skip Intro / Skip Recap hint and the
/// next-episode prompt. They appear seconds apart in the same corner across an episode seam, and
/// before Sodalite#103 they shared nothing but the corner: capsule against rounded rect,
/// `ultraThinMaterial` pinned dark against a scheme-following `thinMaterial`, stroke and shadow
/// against neither.
///
/// The numbers live here rather than at the two call sites so a retune moves both. Both tiers are
/// declared unconditionally, with only the selection behind `#if`, so a test and a Mac-side
/// `ImageRenderer` sheet can see the tvOS geometry from whatever platform they run on.
struct PlayerPillMetrics: Sendable {
    let labelSize: CGFloat
    let metadataSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let iconSpacing: CGFloat
    /// Line height of the label font, measured with `NSFont.systemFont(ofSize:weight: .semibold)`.
    /// The countdown ring is sized to it, so a pill carrying a countdown is exactly as tall as one
    /// that does not, and the skip pill keeps the height it ships with today.
    let labelLineHeight: CGFloat
    let metadataLineHeight: CGFloat
    let stackSpacing: CGFloat
    /// Width of the frame the next-episode stack is positioned in. Sized off the WIDEST localized
    /// label, not the English one: ru "Следующий эпизод" comes to 367pt with ring and padding against
    /// 265pt for "Next Episode" (`NSString.size(withAttributes:)` over all 26 locales). The pill
    /// itself hugs its content; this frame only has to hold the widest of them, and give the metadata
    /// line above it something to truncate against.
    let stackWidth: CGFloat
    /// Distance from the trailing and bottom screen edges. Both pills read it from here, which is
    /// what makes "the same corner" a fact rather than two literals that agree today.
    let marginX: CGFloat
    let marginY: CGFloat

    var labelFont: Font { .system(size: labelSize, weight: .semibold) }
    var metadataFont: Font { .system(size: metadataSize, weight: .medium) }
    var pillHeight: CGFloat { labelLineHeight + verticalPadding * 2 }
    /// How far the metadata line may reach past the pill on EACH side. Centred on a pill that sits
    /// flush against the margin, the line can otherwise be no wider than the pill itself, which cost
    /// real title: 266pt holds ~21 characters where the old trailing-aligned frame held ~35, so
    /// "S2, E4 · Plates, plates, plates" truncated where it used to fit. Half the margin buys most of
    /// that back and still leaves the line as far from the screen edge as the margin allows.
    var metadataOverhang: CGFloat { marginX / 2 }
    var stackHeight: CGFloat { metadataLineHeight + stackSpacing + pillHeight }

    /// Ring diameter follows the label line height, so the countdown costs no pill height. It costs
    /// no label width either: `· 8` in the label would run to ~60pt on tvOS, on a pill whose width
    /// the absolute positioning has to know up front.
    var ringDiameter: CGFloat { labelLineHeight }

    /// tvOS `.body` is 29pt, `.caption` 25pt. The sizes are spelled out rather than taken from the
    /// text style so the measured line heights beside them mean something on any platform this is
    /// read from. The metadata line is deliberately lighter than the pill label: it is the part the
    /// viewer may read, the pill is the part they act on.
    static let tv = PlayerPillMetrics(
        labelSize: 29, metadataSize: 25,
        horizontalPadding: 24, verticalPadding: 14, iconSpacing: 10,
        labelLineHeight: 34, metadataLineHeight: 30,
        stackSpacing: 10, stackWidth: 420, marginX: 80, marginY: 80
    )
    /// iOS `.subheadline` is 15pt; the widest localized label comes to 215pt there.
    static let touch = PlayerPillMetrics(
        labelSize: 15, metadataSize: 14,
        horizontalPadding: 18, verticalPadding: 11, iconSpacing: 10,
        labelLineHeight: 18, metadataLineHeight: 17,
        stackSpacing: 8, stackWidth: 300, marginX: 24, marginY: 28
    )

    #if os(tvOS)
    static let current = tv
    #else
    static let current = touch
    #endif
}

/// Chrome of a floating player pill. The edge stays a literal rather than `Color.Theme.panelEdge`:
/// #106 measured its edges against panels the app draws the ground for, and left values that only
/// nearly match a token alone. This one sits over arbitrary moving video, where 0.12 is the
/// difference between an edge and nothing.
struct PlayerGlassPill: ViewModifier {
    var metrics: PlayerPillMetrics = .current

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}

extension View {
    func playerGlassPill(metrics: PlayerPillMetrics = .current) -> some View {
        modifier(PlayerGlassPill(metrics: metrics))
    }
}

/// Label of a floating pill: a leading glyph slot and a semibold title, the shape both pills wear.
struct PlayerPillLabel<Icon: View>: View {
    let title: String
    var metrics: PlayerPillMetrics = .current
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: metrics.iconSpacing) {
            icon()
            Text(title)
                .font(metrics.labelFont)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
    }
}

/// The autoplay countdown, drawn as a depleting arc around `play.fill`.
///
/// Only the arc, no track behind it: a track would be a new white level over a material that already
/// lightens what is behind it, and the arc alone is what Apple's own end-of-episode button draws.
/// `nextEpisodeCountdown` is an `Int` ticked once a second, so the arc is interpolated here rather
/// than stepped, otherwise it jerks ten times instead of draining.
///
/// Sized by an explicit diameter rather than a text style, because the two hosts measure differently:
/// the floating pill hands it the label's line height so the ring costs no pill height, and the
/// transport chip hands it `UIFont.preferredFont(forTextStyle: .callout).lineHeight` so the ring is
/// exactly as tall as the glyph it stands in for on the chips beside it.
struct CountdownRingIcon: View {
    /// 1…0, or nil where there is no countdown to draw (autoplay off, countdown off, PiP advance).
    let progress: Double?
    let diameter: CGFloat

    private var hasRing: Bool { progress != nil }
    private var lineWidth: CGFloat { max(2, (diameter * 0.09).rounded()) }
    /// SF Symbols centres `play.fill` on its LAYOUT box, and a right-pointing triangle carries its
    /// mass at the base, so a box-centred glyph reads left of centre inside a ring. Apple's own
    /// `play.circle.fill` puts the triangle's ink box at +0.033 of the disc diameter (measured off
    /// the rendered symbol); ours landed at +0.008 on a device screenshot, least-squares circle fit
    /// on the arc, so this closes the difference rather than inventing a taste value. Only with a
    /// ring: without one there is no circle to be concentric with, and the skip pill's glyph beside
    /// it is untouched.
    private var glyphNudge: CGFloat { hasRing ? diameter * 0.025 : 0 }
    /// Inside a ring the glyph has to clear the stroke. With no ring it takes the space the ring
    /// would have used, so a prompt with the countdown switched off reads like the skip pill beside
    /// it rather than like a shrunken one.
    ///
    /// The glyph is always DRAWN at the larger of the two and scaled down, because a `Font` size is
    /// not animatable and `scaleEffect` is. The scale is the ratio of the two rounded sizes, so the
    /// ringed glyph still lands on exactly the size it would have been given directly.
    private var restingGlyphSize: CGFloat { (0.85 * diameter).rounded() }
    private var ringedGlyphSize: CGFloat { (0.5 * diameter).rounded() }
    private var glyphScale: CGFloat { hasRing ? ringedGlyphSize / restingGlyphSize : 1 }

    var body: some View {
        ZStack {
            // Always in the tree, so the arrival has an identity to animate rather than an insertion
            // to pop. Without an outro segment the prompt shows at 30s remaining and the countdown
            // only starts at 10s (PlayerViewModel, no-outro branch), so this arrival is a thing the
            // viewer sits and watches, 20 seconds after the pill itself slid in.
            Circle()
                .trim(from: 0, to: progress ?? 1)
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // It settles INWARD onto the glyph rather than sweeping the arc on from zero: the
                // trim IS the remaining fraction, and drawing it on would show a number that is not
                // the countdown for as long as the animation runs. Starting oversize rather than
                // undersize is what keeps the two apart: growing from 0.55 put the ring inside the
                // still-full-size triangle for the first third, and the glyph read as bursting out
                // of it (filmstrip, 2026-09-04).
                .scaleEffect(hasRing ? 1 : 1.12)
                .opacity(hasRing ? 1 : 0)
                .animation(.linear(duration: 1), value: progress)

            Image(systemName: "play.fill")
                .font(.system(size: restingGlyphSize))
                .scaleEffect(glyphScale)
                // After the scale, so the nudge stays a fraction of the RING, not of the glyph.
                .offset(x: glyphNudge)
        }
        .frame(width: diameter, height: diameter)
        // One curve for the whole arrival: the ring blooms while the glyph shrinks into it and
        // slides onto its optical centre. Matches the spring the action buttons reflow with.
        .animation(.smooth(duration: 0.32), value: hasRing)
    }
}

enum NextEpisodeCountdown {
    /// Remaining fraction for the ring, or nil when there is no countdown running. `total` is what
    /// the countdown STARTED from (the user's setting, or the actual remaining seconds on the
    /// no-outro fallback), not the fixed default: a 5s and a 30s countdown must both drain one full
    /// turn of the ring.
    static func ringProgress(remaining: Int, total: Int) -> Double? {
        guard total > 0, remaining > 0 else { return nil }
        return min(1, Double(remaining) / Double(total))
    }
}

/// The next-episode prompt: a fixed-chrome pill with the metadata line above it, both trailing
/// aligned (Sodalite#103).
///
/// The metadata is a separate label rather than pill content because it is the only part whose width
/// varies per episode: folded into the label it would run past twice the width of the card it
/// replaces on a long title, and change width every episode. Outside it, the pill stays one size and
/// the title truncates.
///
/// Takes plain values, not a `JellyfinItem`, so the whole surface renders on a Mac.
struct NextEpisodePill: View {
    let title: String
    /// `S2, E4 · Plates, plates, plates`, or nil for a movie reached through a shuffle queue.
    let metadata: String?
    let countdownProgress: Double?
    /// Frame the stack is trailing-aligned in. Normally `metrics.stackWidth`; a portrait phone
    /// clamps it to what is left beside the margins.
    let width: CGFloat
    var metrics: PlayerPillMetrics = .current

    var body: some View {
        PlayerPillLabel(title: title, metrics: metrics) {
            CountdownRingIcon(progress: countdownProgress, diameter: metrics.ringDiameter)
        }
        .playerGlassPill(metrics: metrics)
        // Centred on the PILL, not on the frame, and carried as an overlay so it cannot push the
        // pill off its anchor: a stack would size to the wider of the two, and the pill would then
        // drift away from the trailing margin by half the title's overhang, differently every
        // episode. The overlay is proposed the pill's width, so the line centres over the button and
        // truncates at its edges instead of reaching into the screen margin.
        .overlay(alignment: .top) {
            if let metadata {
                Text(metadata)
                    .font(metrics.metadataFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The card put this text on a material; here it sits on the video itself, so it
                    // carries its own separation. Tuned against a bright frame, where a plain white
                    // line disappears (ImageRenderer sheet, 2026-09-04).
                    .shadow(color: .black.opacity(0.75), radius: 6, y: 2)
                    .frame(maxWidth: .infinity)
                    // The overlay is proposed the PILL's width; negative padding widens that
                    // proposal symmetrically, so the line still centres on the button but is no
                    // longer bounded by it. See `metadataOverhang`.
                    .padding(.horizontal, -metrics.metadataOverhang)
                    .offset(y: -(metrics.metadataLineHeight + metrics.stackSpacing))
            }
        }
        // Explicit height so the absolute `.position` in PlayerOverlayView keeps measuring the whole
        // prompt: the overlay draws outside the pill and contributes nothing to its intrinsic size.
        .frame(width: width, height: metrics.stackHeight, alignment: .bottomTrailing)
    }
}
