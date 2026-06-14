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

    /// Prominent buttons (the primary Play/Resume action) always show
    /// their title. Secondary buttons show it only when the row opted
    /// into collapsing is off, or while focused.
    private var showsLabel: Bool {
        !collapsesLabel || isProminent || isFocused
    }

    var body: some View {
        HStack(spacing: showsLabel ? 10 : 0) {
            if isLoading {
                // Spinner alongside the title so the button keeps its
                // size + remains recognisable; replacing the whole label
                // with a small spinner made the button shrink and
                // visually disappear during the wait.
                ProgressView()
                    .controlSize(.small)
                if showsLabel {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: systemImage)
                    .font(.body)
                if showsLabel {
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
            }
        }
        // Icon-only pills get tighter horizontal padding so they read as
        // compact circles rather than wide empty capsules.
        .padding(.horizontal, showsLabel ? 24 : 18)
        .padding(.vertical, 12)
        // Keep the label at its intrinsic width so a multi-element
        // prominent button (icon + title + subtitle, e.g. the resume
        // button) is never compressed by the action row's width
        // distribution, which otherwise hyphenated "Fortsetzen" onto
        // two lines. The button grows to fit its content instead.
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
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
    /// `EnvironmentValues.collapsesActionButtonLabel`).
    func collapsesActionButtonLabel(_ collapses: Bool = true) -> some View {
        environment(\.collapsesActionButtonLabel, collapses)
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
            .animation(.easeInOut(duration: 0.15), value: isFocused)
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
