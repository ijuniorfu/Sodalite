import SwiftUI

struct GlassActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    /// Prominent variant wears destructive red instead of accent; non-prominent destructive stays neutral grey (role still applied for VoiceOver).
    var isDestructive: Bool = false
    /// Inline secondary label (e.g. resume "S1E5 · 12:34"); caption + 0.75 opacity so it reads as metadata, not a competing title.
    var subtitle: String? = nil
    /// 0…1 progress overlay behind the label (resume tile, accent fill); nil suppresses it.
    var progressFraction: Double? = nil
    /// Replaces the label with a spinner and disables the button while the host resolves the play target (e.g. series play waits on getNextUp); quieter than flipping the title mid-render.
    var isLoading: Bool = false
    let action: () -> Void

    /// When set via `.collapsesActionButtonLabel(true)`, secondary buttons collapse to an icon-only pill revealing the title on focus, so a crowded row (Bluey: 8 actions) fits.
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
        // Keep the title for VoiceOver even when the visible label collapses to an icon-only pill.
        .accessibilityLabel(Text(title))
    }
}

/// Own view so it can read `@Environment(\.isFocused)` from inside the button's subtree (same value GlassButtonStyle keys its ring off).
private struct GlassActionButtonLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let subtitle: String?
    let isProminent: Bool
    let isLoading: Bool
    let collapsesLabel: Bool

    @Environment(\.isFocused) private var isFocused
    /// Measured intrinsic width of the trailing title/subtitle (leading gap baked in); the visible copy animates its frame 0→this so text fades in step with the growing width.
    @State private var labelWidth: CGFloat = 0

    /// Prominent buttons always show the title; secondary ones only when the row hasn't opted into collapsing, or while focused.
    private var showsLabel: Bool {
        !collapsesLabel || isProminent || isFocused
    }

    /// Falls back to `nil` (intrinsic) before measurement so the auto-focused Play button doesn't flash open from zero width.
    private var labelFrameWidth: CGFloat? {
        guard showsLabel else { return 0 }
        return labelWidth > 0 ? labelWidth : nil
    }

    /// Collapsible trailing content (title + optional subtitle); leading-glyph gap baked in so the measured width accounts for it.
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
        // Tighter padding for icon-only pills so they read as compact circles, not wide capsules.
        .padding(.horizontal, showsLabel ? 24 : 18)
        .padding(.vertical, 12)
        .fixedSize(horizontal: true, vertical: false)
        // Hidden full-size copy in a background (never stretches its primary) measures the true intrinsic width even while the visible copy is clipped to zero.
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
        // Width reveal + padding shift are animated by the row's shared transaction (CollapsingActionRowModifier) so all siblings interpolate together; no per-button animation here.
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
    /// Whether secondary buttons in this subtree collapse to icon-only, revealing the title on focus; default false keeps always-labelled (sheets, one-offs).
    var collapsesActionButtonLabel: Bool {
        get { self[CollapsesActionButtonLabelKey.self] }
        set { self[CollapsesActionButtonLabelKey.self] = newValue }
    }
}

extension View {
    /// Opt this row into icon-only secondary buttons and animate its reflow on focus change.
    func collapsesActionButtonLabel(_ collapses: Bool = true) -> some View {
        modifier(CollapsingActionRowModifier(collapses: collapses))
    }
}

/// Forces a shared spring onto every transaction in the row so focus change + label reveal + all sibling shifts interpolate in one pass. `.transaction` (not preference-keyed `.animation(value:)`, which lagged a frame and let distant buttons snap) rides the focus change so the row reflows as a unit.
private struct CollapsingActionRowModifier: ViewModifier {
    let collapses: Bool
    /// Gates the forced animation off until the row has settled in. The transaction otherwise animates the row's FIRST layout too, which during a fullScreenCover present interpolated the buttons from their initial frame and read as a "fly in from the top". After settling, focus-change reflows animate as before.
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .environment(\.collapsesActionButtonLabel, collapses)
            .transaction { txn in
                txn.animation = settled ? .smooth(duration: 0.32) : nil
            }
            .onAppear {
                deferOnMain(by: 0.35) { settled = true }
            }
    }
}

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    /// With `isProminent`, makes the fill destructive red; non-prominent destructive stays grey (parent Button's role handles VoiceOver).
    var isDestructive: Bool = false
    /// 0…1 resume-progress fill behind the label, accent-tinted; ignored when nil.
    var progressFraction: Double? = nil
    @Environment(\.isFocused) private var isFocused

    /// A progress-overlay tile drops its prominent fill: the accent backdrop drowned out the accent progress capsule, so it falls back to neutral grey to let the capsule pop.
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
                        // Clip the inner fill to the outer capsule so a fraction near 1.0 doesn't bleed past the rounded edge.
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
            // Matches the label-reveal spring so scale, border and icon→label expansion move together.
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
