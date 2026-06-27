import SwiftUI

/// Post-update modal showing the latest release's highlights; fires once after upgrade, then ChangelogPreferences marks it seen. Dismiss button pinned to bottom safe-area inset so it never gets pushed off.
struct WhatsNewView: View {
    let entry: ChangelogEntry
    let onDismiss: () -> Void

    /// Focus-scope namespace so the first highlight row takes default focus, not the leading-top safeAreaInset dismiss button.
    @Namespace private var focusNamespace

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                highlightsList
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .focusScopeCompat(focusNamespace)
        // Bottom edge-fade "scrollable" cue, only the bottom 6% so a focused edge highlight stays readable.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Near-opaque black so content behind the modal doesn't bleed through (0.85 was visibly translucent over the catalog grid).
        .background(Color.black.opacity(0.96).ignoresSafeArea())
        // Pin the Got-it CTA to the bottom edge so it stays visible however tall the list grows.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dismissButton
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.96).ignoresSafeArea(edges: .bottom))
        }
        // Menu button on the Siri Remote also dismisses.
        .onExitCommandCompat { onDismiss() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text(String(localized: "changelog.modal.kicker", defaultValue: "What's New"))
                .font(.headline)
                .foregroundStyle(.tint)
                .textCase(.uppercase)
                .tracking(2)

            // Brand name + version verbatim across languages, no catalog entry needed.
            Text("Sodalite \(entry.version)")
                .font(.system(size: 56, weight: .bold))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.bottom, 50)
    }

    private var highlightsList: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(entry.highlights.enumerated()), id: \.element.id) { index, highlight in
                HighlightRow(highlight: highlight)
                    .prefersDefaultFocusCompat(index == 0, in: focusNamespace)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 80)
        // Padding-as-margin (not a trailing spacer) so a single down-press from the last row routes to the dismiss button, not into empty scroll space.
        .padding(.bottom, 40)
    }

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            Text(String(
                localized: "changelog.modal.dismiss",
                defaultValue: "Got it"
            ))
            .font(.body)
            .fontWeight(.semibold)
            .padding(.horizontal, 56)
            .padding(.vertical, 16)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .padding(.vertical, 30)
    }
}

private struct HighlightRow: View {
    let highlight: ChangelogHighlight

    // @FocusState not @Environment(\.isFocused): latter doesn't propagate into a plain .focusable() View on tvOS.
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            iconBubble

            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                if let description = highlight.description {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isFocused ? .white.opacity(0.15) : .white.opacity(0.05))
        )
        // Same SettingsTileButtonStyle accent-tint stroke + lift.
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        )
        .scaleEffect(isFocused ? 1.03 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 15, y: 8)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        // Focusable so the tvOS focus engine has a scroll anchor; without it a long changelog can't be scrolled.
        .focusable()
        .focused($isFocused)
    }

    private var iconBubble: some View {
        ZStack {
            Circle()
                .fill(tintForKind.opacity(0.18))
            Image(systemName: highlight.systemImage)
                .font(.title2)
                .foregroundStyle(tintForKind)
        }
        .frame(width: 60, height: 60)
    }

    private var tintForKind: Color {
        // Fixed status colours, not the user's accent: these are status indicators, not brand surfaces.
        switch highlight.kind {
        case .new: return .blue
        case .improve: return .green
        case .fix: return .orange
        }
    }
}
