import SwiftUI

/// Post-update modal showing the latest release's highlights.
/// Fires once after the user upgrades, then `ChangelogPreferences`
/// marks the version seen and the modal stays out of the way until
/// the next bump. Mirrors the visual treatment of native tvOS
/// "What's New" sheets — large title, icon row, dismiss CTA.
struct WhatsNewView: View {
    let entry: ChangelogEntry
    let onDismiss: () -> Void

    @FocusState private var dismissFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            highlightsList
            Spacer(minLength: 0)
            dismissButton
        }
        .frame(maxWidth: 1100, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.85))
        .ignoresSafeArea()
        .onAppear {
            // tvOS deferred-focus pattern — letting the focus settle
            // on the dismiss button after the sheet's transition
            // means the user can immediately press Play/Pause to
            // close without arrow-keying down through the list.
            DispatchQueue.main.async {
                dismissFocused = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text(String(localized: "changelog.modal.kicker", defaultValue: "What's New"))
                .font(.headline)
                .foregroundStyle(.tint)
                .textCase(.uppercase)
                .tracking(2)

            // Brand name + version is fixed across languages — no
            // need for a catalog entry. Splitting kicker (localized)
            // from title (verbatim) keeps the dynamic part out of
            // the LocalizedStringResource interpolation chain.
            Text("JellySeeTV \(entry.version)")
                .font(.system(size: 56, weight: .bold))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.bottom, 50)
    }

    private var highlightsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(entry.highlights) { highlight in
                    HighlightRow(highlight: highlight)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 80)
        }
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
        .focused($dismissFocused)
        .padding(.bottom, 80)
        .padding(.top, 30)
    }
}

private struct HighlightRow: View {
    let highlight: ChangelogHighlight

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
        // Map the kind to a recognizable colour without relying on
        // the user's accent — these are status indicators, not
        // brand surfaces.
        switch highlight.kind {
        case .new: return .blue
        case .improve: return .green
        case .fix: return .orange
        }
    }
}
