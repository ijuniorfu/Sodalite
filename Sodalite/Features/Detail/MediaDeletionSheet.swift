import SwiftUI

/// Confirmation sheet for the File Management feature. One view covers
/// three scopes via the `Mode` enum: a single movie, an entire series,
/// or one or more individually-selected seasons.
///
/// Visibility of the parent Delete button is gated on the active
/// user's `canDeleteContent` property, which already reacts to profile
/// switches (AppState.activeUser is @Observable). The server is the
/// final authority — a 403 from Jellyfin during a stale-policy window
/// surfaces as the standard partial-failure toast.
///
/// Visual language: all interactive rows use `BoolPillRow` (defined
/// below, focus-friendly capsule with white text + accent stroke).
/// All footer buttons use `GlassActionButton` so the sheet matches the
/// detail-view's own action row. Native `Toggle` and `.bordered` /
/// `.borderedProminent` were tried first and rendered with invisible
/// labels on tvOS focus state, hence the bespoke rows.
struct MediaDeletionSheet: View {
    /// Scope of the deletion. The view's body branches on this.
    enum Mode: Equatable {
        case movie(itemID: String, tmdbID: Int?, title: String)
        case series(itemID: String, tmdbID: Int?, title: String, seasons: [SeasonOption])
    }

    /// One row in the series season-picker. `id` is the Jellyfin item id
    /// of the season; `seasonNumber` is the display number, `title` is
    /// the localised "Season 1" / "Specials" string Jellyfin returns.
    struct SeasonOption: Identifiable, Equatable {
        let id: String
        let seasonNumber: Int
        let title: String
    }

    let mode: Mode
    /// Invoked when the user confirms. The closure receives the chosen
    /// cascade flag and (for series) the season selection. The sheet
    /// stays open until the action's async work completes; the parent
    /// is responsible for calling `dismiss()` once it finishes.
    let onConfirm: (DeletionRequest) async -> DeletionOutcome
    @Environment(\.dismiss) private var dismiss

    /// What the parent receives. For movie + entire-series cases the
    /// `seasonItemIDs` array is empty.
    struct DeletionRequest {
        let cascadeToArrStack: Bool
        /// `true` for the series-wide case, `false` for season-level.
        let deleteEntireSeries: Bool
        let seasonItemIDs: [String]
    }

    /// What the parent reports back. The sheet uses this to decide
    /// which toast to show (or none, and dismiss).
    enum DeletionOutcome: Equatable {
        case success
        case partialSuccess(message: String)
        case failure(message: String)
    }

    // MARK: - Local state

    @State private var cascadeToArrStack: Bool = true
    @State private var deleteEntireSeries: Bool = false
    @State private var selectedSeasonIDs: Set<String> = []
    @State private var isDeleting: Bool = false
    @State private var toast: DeletionOutcome?

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 28) {
                header

                switch mode {
                case .movie:
                    movieBody
                case .series(_, _, _, let seasons):
                    seriesBody(seasons: seasons)
                }

                Spacer()

                footer
            }
            .padding(48)
            .frame(maxWidth: 800)

            // Outcome toast slides up from the bottom once the delete
            // call returns. The in-flight feedback is on the Delete
            // button itself (spinner + title via GlassActionButton's
            // isLoading), no second indicator needed.
            if let toast = toast {
                toastView(toast)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 48)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("delete.confirm.title")
                .font(.title2)
                .fontWeight(.semibold)
            Text(titleSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var titleSubtitle: String {
        switch mode {
        case .movie(_, _, let title): return title
        case .series(_, _, let title, _): return title
        }
    }

    private var movieBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            cascadePillRow(disabled: false)
            Text("delete.confirm.movie.body")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seriesBody(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BoolPillRow(
                title: "delete.confirm.series.entire",
                isOn: $deleteEntireSeries,
                disabled: false
            )
            .onChange(of: deleteEntireSeries) { _, newValue in
                // Switching to whole-series clears any season selection
                // so the visual state stays coherent.
                if newValue { selectedSeasonIDs.removeAll() }
            }

            if !deleteEntireSeries {
                seasonList(seasons: seasons)
            }

            cascadePillRow(disabled: !deleteEntireSeries)

            if !deleteEntireSeries {
                Text("delete.confirm.cascade.seasonsFootnote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cascadePillRow(disabled: Bool) -> some View {
        BoolPillRow(
            title: "delete.confirm.cascade.title",
            isOn: $cascadeToArrStack,
            disabled: disabled
        )
        .onChange(of: disabled) { _, isDisabled in
            // Force off when disabled so the parent never sees a
            // cascade=true with seasons-only selection.
            if isDisabled { cascadeToArrStack = false }
        }
    }

    private func seasonList(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("delete.confirm.series.seasons")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(seasons) { season in
                BoolPillRow(
                    title: LocalizedStringKey(season.title),
                    isOn: Binding(
                        get: { selectedSeasonIDs.contains(season.id) },
                        set: { isOn in
                            if isOn {
                                selectedSeasonIDs.insert(season.id)
                            } else {
                                selectedSeasonIDs.remove(season.id)
                            }
                        }
                    ),
                    disabled: false
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 24) {
            GlassActionButton(
                title: "common.cancel",
                systemImage: "xmark",
                action: { dismiss() }
            )
            .disabled(isDeleting)

            GlassActionButton(
                title: "delete.confirm.deleteButton",
                systemImage: "trash",
                isProminent: true,
                isDestructive: true,
                isLoading: isDeleting,
                action: { Task { await performDelete() } }
            )
            .disabled(isDeleting || !canConfirm)
        }
    }

    private func toastView(_ outcome: DeletionOutcome) -> some View {
        let (text, color): (String, Color) = {
            switch outcome {
            case .success:
                return (String(localized: "delete.toast.success"), .green)
            case .partialSuccess(let msg):
                return (msg, .orange)
            case .failure(let msg):
                return (msg, .red)
            }
        }()
        return Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.9))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - State helpers

    /// True when at least one valid deletion target is selected.
    private var canConfirm: Bool {
        switch mode {
        case .movie:
            return true
        case .series:
            return deleteEntireSeries || !selectedSeasonIDs.isEmpty
        }
    }

    private func performDelete() async {
        isDeleting = true
        defer { isDeleting = false }

        let request = DeletionRequest(
            cascadeToArrStack: cascadeToArrStack,
            deleteEntireSeries: {
                if case .movie = mode { return false }
                return deleteEntireSeries
            }(),
            seasonItemIDs: deleteEntireSeries ? [] : Array(selectedSeasonIDs)
        )
        let outcome = await onConfirm(request)
        toast = outcome
        if case .success = outcome {
            // Brief hold so the user sees the success indicator before
            // the sheet auto-dismisses. Failure / partialSuccess toasts
            // stay until the user presses Cancel.
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}

// MARK: - BoolPillRow

/// Focus-friendly inline toggle. Mirrors `ValuePickerRow` from
/// `PlaybackSettingsView` so both surfaces feel the same under focus.
/// Uses `.focusable(true)` rather than a `Button` because tvOS's
/// `Button` focus chrome (a bright pill outline) bleeds through even
/// with `.focusEffectDisabled()` on top of `.ultraThinMaterial` — the
/// raw focusable surface lets our accent stroke be the only focus
/// indicator. Trailing icon shows the on/off state at a glance.
private struct BoolPillRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var disabled: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.5)))
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        // Background + stroke read `.tint` from the environment
        // (`SodaliteApp` sets `.tint(effectiveTint(...))` at WindowGroup
        // level so the user's chosen accent / supporter color applies).
        // Don't use `Color.accentColor` here — that reads the static
        // `AccentColor` asset, which is hard-coded to system blue and
        // doesn't follow the per-session tint.
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused ? AnyShapeStyle(TintShapeStyle.tint.opacity(0.18)) : AnyShapeStyle(Color.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.02 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.25 : 0), radius: 10, y: 5)
        .focusable(!disabled)
        .focused($focused)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .stableTap(isFocused: focused) {
            if !disabled { isOn.toggle() }
        }
    }
}
