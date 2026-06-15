import SwiftUI

/// Feature #4 overlay: search + pick a subtitle to download for the
/// current item. Bound to `PlayerViewModel`'s subtitle-search state.
///
/// Focus + activation follow the canonical Sodalite interactive-overlay
/// convention (see `VersionPickerSheet`): each row owns a `@FocusState`
/// entry, `.focusable(true)` + `.focused($state, equals:)` for remote
/// navigation, `.stableTap` for the focus-stability-gated clickpad press,
/// and the focused row fills with the player tint (black foreground), not
/// white. The player tint flows in from `PlayerHostController.init(tintColor:)`
/// via the `tint` parameter, never `Color.accentColor` directly.
struct SubtitleSearchView: View {
    @Bindable var viewModel: PlayerViewModel
    /// The player tint. Mounted with the same `tintColor` the host applies
    /// to the whole overlay via `.tint(...)` (see `PlayerOverlayView`); the
    /// focused-row fill needs the concrete `Color`, not the environment
    /// tint shape style, so it is threaded in explicitly.
    var tint: Color

    /// Focus identity for the rows. Language chips are keyed by their
    /// 3-letter code; result rows by the remote subtitle id. A single
    /// `@FocusState` across both groups lets the remote walk from the
    /// language switcher down into the result list naturally.
    @FocusState private var focusedRow: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text("player.subtitle.search.title")
                    .font(.title2.weight(.semibold))

                languageSwitcher

                content
            }
            .padding(40)
            .frame(maxWidth: 900, maxHeight: 700)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
        .tint(tint)
        .onExitCommand { viewModel.dismissSubtitleSearch() }
        .onAppear { restoreFocus() }
        .onChange(of: viewModel.subtitleSearchState) { _, _ in restoreFocus() }
    }

    /// Parks focus on a sensible default whenever the content changes
    /// shape (search re-run, results arriving). Prefers the active
    /// language chip so the switcher is reachable; the user can step
    /// down into the result list from there.
    private func restoreFocus() {
        if focusedRow == nil {
            focusedRow = languageRowID(viewModel.subtitleSearchLanguage)
        }
    }

    private func languageRowID(_ code: String) -> String { "lang.\(code)" }

    // MARK: - Language switcher

    private var languageSwitcher: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(viewModel.subtitleSearchLanguageOptions, id: \.short) { choice in
                    let code = choice.code ?? ""
                    languageChip(code: code, short: choice.short)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func languageChip(code: String, short: String) -> some View {
        let rowID = languageRowID(code)
        let isFocused = focusedRow == rowID
        let isSelected = code == viewModel.subtitleSearchLanguage
        return Text(short)
            .font(.body)
            .fontWeight(isSelected ? .bold : .regular)
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(isFocused ? tint : Color.Theme.surface)
            )
            .overlay(
                Capsule()
                    .strokeBorder(tint, lineWidth: 3)
                    .opacity(!isFocused && isSelected ? 1 : 0)
            )
            .focusable(true)
            .focused($focusedRow, equals: rowID)
            .stableTap(isFocused: isFocused) {
                viewModel.setSubtitleSearchLanguage(code)
            }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch viewModel.subtitleSearchState {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            Text("player.subtitle.search.noResults")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .downloading:
            VStack(spacing: 16) {
                ProgressView()
                Text("player.subtitle.search.downloading")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results(let results):
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(results) { info in
                        resultRow(info)
                    }
                }
            }
        }
    }

    private func resultRow(_ info: RemoteSubtitleInfo) -> some View {
        let isFocused = focusedRow == info.id
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.name ?? info.providerName ?? "Subtitle")
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    if let provider = info.providerName { Text(provider) }
                    if let lang = info.threeLetterISOLanguageName { Text(lang.uppercased()) }
                    if let fmt = info.format { Text(fmt.uppercased()) }
                }
                .font(.caption)
                // Secondary metadata stays legible against the tint fill
                // when focused; .secondary on a saturated tint is muddy.
                .foregroundStyle(isFocused ? Color.black.opacity(0.7) : Color.secondary)
            }
            Spacer()
            if let count = info.downloadCount {
                Label("\(count)", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.7) : Color.secondary)
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? tint : Color.Theme.surface)
        )
        .focusable(true)
        .focused($focusedRow, equals: info.id)
        .stableTap(isFocused: isFocused) {
            Task { await viewModel.downloadAndApplySubtitle(info) }
        }
    }
}
