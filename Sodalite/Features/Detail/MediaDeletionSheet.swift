import SwiftUI

/// Confirmation sheet for the File Management feature. One view covers
/// three scopes via the `Mode` enum: a single movie, an entire series,
/// or one or more individually-selected seasons.
///
/// Visibility of the parent Delete button is gated on the active
/// user's `canDeleteContent` property, which already reacts to profile
/// switches (AppState.activeUser is @Observable). The server is the
/// final authority -- a 403 from Jellyfin during a stale-policy window
/// surfaces as the standard partial-failure toast.
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
        VStack(alignment: .leading, spacing: 32) {
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .top) {
            if let toast = toast {
                toastView(toast)
                    .padding(.top, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
        VStack(alignment: .leading, spacing: 24) {
            cascadeToggle(disabled: false)
            Text("delete.confirm.movie.body")
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    private func seriesBody(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $deleteEntireSeries) {
                Text("delete.confirm.series.entire")
                    .font(.headline)
            }
            .onChange(of: deleteEntireSeries) { _, newValue in
                // Switching to whole-series clears any season selection
                // so the visual state stays coherent.
                if newValue { selectedSeasonIDs.removeAll() }
            }

            seasonList(seasons: seasons)
                .disabled(deleteEntireSeries)
                .opacity(deleteEntireSeries ? 0.4 : 1.0)

            cascadeToggle(disabled: !deleteEntireSeries)
            if !deleteEntireSeries {
                Text("delete.confirm.cascade.seasonsFootnote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func seasonList(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("delete.confirm.series.seasons")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(seasons) { season in
                Button {
                    if selectedSeasonIDs.contains(season.id) {
                        selectedSeasonIDs.remove(season.id)
                    } else {
                        selectedSeasonIDs.insert(season.id)
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: selectedSeasonIDs.contains(season.id)
                            ? "checkmark.square.fill"
                            : "square")
                            .font(.title3)
                        Text(season.title)
                            .font(.body)
                        Spacer()
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func cascadeToggle(disabled: Bool) -> some View {
        Toggle(isOn: $cascadeToArrStack) {
            VStack(alignment: .leading, spacing: 2) {
                Text("delete.confirm.cascade.title")
                Text("delete.confirm.cascade.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
        .onChange(of: disabled) { _, isDisabled in
            // Force off when disabled so the parent never sees a
            // cascade=true with seasons-only selection.
            if isDisabled { cascadeToArrStack = false }
        }
    }

    private var footer: some View {
        HStack(spacing: 24) {
            Button {
                dismiss()
            } label: {
                Text("common.cancel")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.bordered)
            .disabled(isDeleting)

            Button(role: .destructive) {
                Task { await performDelete() }
            } label: {
                if isDeleting {
                    ProgressView()
                        .frame(minWidth: 200)
                } else {
                    Text("delete.confirm.deleteButton")
                        .frame(minWidth: 200)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
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
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(color.opacity(0.85))
            .foregroundStyle(.white)
            .clipShape(Capsule())
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
