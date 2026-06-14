import SwiftUI

struct GlassActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    /// When `true`, the prominent variant wears the system destructive
    /// red instead of the accent colour. Used by the delete-confirmation
    /// sheet's Delete button so the destructive intent is unambiguous;
    /// non-prominent destructive buttons fall back to the neutral grey
    /// fill (with destructive role still applied for VoiceOver). Keeps
    /// the visual language consistent with the rest of the action-row
    /// buttons that never use a non-accent prominent fill.
    var isDestructive: Bool = false
    /// Optional inline secondary label, used by the detail-view
    /// resume button to surface "S1E5 · 12:34" without breaking row
    /// height. Renders in caption + 0.75 opacity so it reads as
    /// supporting metadata, not a competing title.
    var subtitle: String? = nil
    /// Optional 0…1 progress overlay drawn behind the button label.
    /// Used by the resume button to mirror Apple TV+'s convention of
    /// painting the user's progress through the title across the
    /// resume tile in the active accent. nil suppresses the overlay
    /// entirely (fresh content, no progress to show).
    var progressFraction: Double? = nil
    /// When true, the label is replaced with a spinner and the
    /// button is disabled. Used while the host view is still
    /// resolving which content the action will play, e.g. the
    /// series detail's play button waits for getNextUp before it
    /// can decide between "Abspielen" and "Fortsetzen + S1E5".
    /// Showing a placeholder is visually quieter than letting the
    /// title flip mid-render.
    var isLoading: Bool = false
    let action: () -> Void

    /// Set by an action row via `.collapsesActionButtonLabel(true)`.
    /// When on, secondary (non-prominent) buttons collapse to an
    /// icon-only pill and reveal their title only on focus, so a
    /// crowded detail-view row (Bluey: 8 actions) fits on screen.
    @Environment(\.collapsesActionButtonLabel) private var collapsesLabel

    var body: some View {
        Button(role: isDestructive ? .destructive : nil) {
            action()
        } label: {
            GlassActionButtonLabel(
                title: title,
                systemImage: systemImage,
                subtitle: subtitle,
                isProminent: isProminent,
                isLoading: isLoading,
                collapsesLabel: collapsesLabel
            )
        }
        .buttonStyle(GlassButtonStyle(
            isProminent: isProminent,
            isDestructive: isDestructive,
            progressFraction: progressFraction
        ))
        .disabled(isLoading)
        // Preserve the title for VoiceOver even when the visible label
        // collapses to an icon-only pill (unfocused secondary buttons).
        .accessibilityLabel(Text(title))
    }
}

/// The button's label content. Lives in its own view so it can read
/// `@Environment(\.isFocused)` from inside the focused button's subtree
/// (the value the GlassButtonStyle already keys its focus ring off).
private struct GlassActionButtonLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let subtitle: String?
    let isProminent: Bool
    let isLoading: Bool
    let collapsesLabel: Bool

    @Environment(\.isFocused) private var isFocused
    /// Measured intrinsic width of the trailing title/subtitle content
    /// (its leading gap baked in). The visible copy animates its frame
    /// between 0 and this, so the reveal interpolates the real layout
    /// footprint: the text fades in step with the growing width.
    @State private var labelWidth: CGFloat = 0
    /// Stable per-instance id, published up as a preference while this
    /// button holds focus. The enclosing action row keys its row-wide
    /// reflow animation on it so the OTHER buttons glide to their new
    /// positions when focus moves (a per-button animation only covers
    /// the focused button's own geometry, never its siblings' offsets).
    @State private var instanceID = UUID().uuidString

    /// Prominent buttons (the primary Play/Resume action) always show
    /// their title. Secondary buttons reveal it only when the row hasn't
    /// opted into collapsing, or while focused.
    private var showsLabel: Bool {
        !collapsesLabel || isProminent || isFocused
    }

    /// Animated frame width for the collapsible label. Falls back to
    /// `nil` (intrinsic) on the very first frame before measurement so
    /// the auto-focused Play button never flashes open from zero width.
    private var labelFrameWidth: CGFloat? {
        guard showsLabel else { return 0 }
        return labelWidth > 0 ? labelWidth : nil
    }

    /// The collapsible trailing content: title plus the optional resume
    /// subtitle, with the gap to the leading glyph baked in so the
    /// measured width already accounts for it.
    private var labelInner: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.leading, 10)
        .fixedSize()
    }

    var body: some View {
        HStack(spacing: 0) {
            if isLoading {
                // Spinner instead of the icon while the host resolves the
                // play target; the label still reveals on focus as usual.
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.body)
            }

            labelInner
                .frame(width: labelFrameWidth, alignment: .leading)
                .opacity(showsLabel ? 1 : 0)
                .clipped()
        }
        // Icon-only pills get tighter horizontal padding so they read as
        // compact circles rather than wide empty capsules.
        .padding(.horizontal, showsLabel ? 24 : 18)
        .padding(.vertical, 12)
        .fixedSize(horizontal: true, vertical: false)
        // Hidden full-size copy measures the label's intrinsic width
        // without contributing to layout (a background never stretches
        // its primary). The GeometryReader sits in the fixed-size copy's
        // own background, so it reports the true intrinsic width even
        // while the visible copy is clipped to zero.
        .background(alignment: .leading) {
            labelInner
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: ActionLabelWidthKey.self, value: geo.size.width
                    )
                })
        }
        .onPreferenceChange(ActionLabelWidthKey.self) { labelWidth = $0 }
        // Spring matched to GlassButtonStyle's scale so the reveal and
        // the padding shift move as one. Keyed on showsLabel only: a
        // later width remeasure (e.g. resume time updating) snaps
        // without animating.
        .animation(.smooth(duration: 0.32), value: showsLabel)
        // Publish focus up so the row can animate its reflow (see
        // CollapsingActionRowModifier).
        .preference(key: FocusedActionLabelKey.self, value: isFocused ? instanceID : nil)
    }
}

private struct FocusedActionLabelKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

private struct ActionLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Collapse opt-in environment

private struct CollapsesActionButtonLabelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether secondary GlassActionButtons in this subtree collapse to
    /// icon-only and reveal their title on focus. Default false keeps
    /// the always-labelled behaviour (sheets, one-off buttons).
    var collapsesActionButtonLabel: Bool {
        get { self[CollapsesActionButtonLabelKey.self] }
        set { self[CollapsesActionButtonLabelKey.self] = newValue }
    }
}

extension View {
    /// Opt this action row into icon-only secondary buttons (see
    /// `EnvironmentValues.collapsesActionButtonLabel`) and animate the
    /// row's reflow when focus moves between buttons.
    func collapsesActionButtonLabel(_ collapses: Bool = true) -> some View {
        modifier(CollapsingActionRowModifier(collapses: collapses))
    }
}

/// Sets the collapse environment and, crucially, keys a row-wide spring
/// on the focused button's id. When focus moves the id changes, so the
/// `.animation(value:)` transaction covers the whole HStack's relayout
/// and the sibling buttons glide to their new offsets instead of
/// snapping. (A per-button animation can only interpolate the focused
/// button's own frame; the siblings' position changes belong to the
/// parent's layout pass and need the animation applied here.)
private struct CollapsingActionRowModifier: ViewModifier {
    let collapses: Bool
    @State private var focusedActionID: String?

    func body(content: Content) -> some View {
        content
            .environment(\.collapsesActionButtonLabel, collapses)
            .onPreferenceChange(FocusedActionLabelKey.self) { focusedActionID = $0 }
            .animation(.smooth(duration: 0.32), value: focusedActionID)
    }
}

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    /// Pairs with `isProminent`. When true, the prominent fill becomes
    /// the system destructive red instead of the accent colour. Non-
    /// prominent destructive buttons stay on the neutral grey fill;
    /// the destructive role on the parent Button handles VoiceOver.
    var isDestructive: Bool = false
    /// 0…1, ignored when nil. Drives the resume-progress fill rendered
    /// behind the label. The bar wears the accent tint so it picks up
    /// whatever colour the user has selected for the rest of the UI.
    var progressFraction: Double? = nil
    @Environment(\.isFocused) private var isFocused

    /// A tile that wears a progress overlay drops its prominent fill
    ///, the accent-coloured backdrop drowned out the accent-coloured
    /// progress capsule and the bar read as a barely-visible shade
    /// difference. Falling back to the neutral grey fill the other
    /// detail-row buttons use lets the progress capsule pop in full
    /// tint colour against the muted base.
    private var effectivelyProminent: Bool {
        isProminent && (progressFraction ?? 0) <= 0
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(backgroundFill)

                    if let fraction = progressFraction, fraction > 0 {
                        GeometryReader { geo in
                            Capsule()
                                .fill(.tint.opacity(isFocused ? 0.95 : 0.85))
                                .frame(width: geo.size.width * CGFloat(min(1.0, fraction)))
                        }
                        // Shape the inner fill to the outer capsule so
                        // a fraction near 1.0 doesn't bleed past the
                        // pill's rounded edge on either side.
                        .clipShape(Capsule())
                    }
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.95 : 1.0))
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
            // Matches the label-reveal spring in GlassActionButtonLabel so
            // scale, border and the icon->label expansion move together.
            .animation(.smooth(duration: 0.32), value: isFocused)
    }

    private var backgroundFill: AnyShapeStyle {
        if effectivelyProminent {
            if isDestructive {
                return AnyShapeStyle(Color.red.opacity(isFocused ? 0.9 : 0.7))
            }
            return AnyShapeStyle(TintShapeStyle.tint.opacity(isFocused ? 0.9 : 0.7))
        }
        return AnyShapeStyle(.white.opacity(isFocused ? 0.2 : 0.1))
    }
}
