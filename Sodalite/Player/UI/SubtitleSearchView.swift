import SwiftUI

/// Feature #4 overlay: search + pick a subtitle to download for the
/// current item. DISPLAY-ONLY: it renders highlight from
/// `viewModel.subtitleSearchFocus`. All remote input is routed by
/// PlayerHostController's press handlers, because the player host has
/// user interaction disabled (like every other player overlay).
struct SubtitleSearchView: View {
    @Bindable var viewModel: PlayerViewModel
    var tint: Color

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                Text("player.subtitle.search.title")
                    .font(.title2.weight(.semibold))
                languageSwitcher
                content
            }
            .padding(48)
            .frame(width: 1000, height: 760)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    private var languageSwitcher: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(viewModel.subtitleSearchLanguageOptions.enumerated()), id: \.offset) { idx, choice in
                        let isFocused = viewModel.subtitleSearchFocus == .language(idx)
                        let isSelected = choice.code == viewModel.subtitleSearchLanguage
                        Text(choice.short)
                            .fontWeight(isSelected ? .bold : .regular)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isFocused ? tint : Color.white.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(isSelected && !isFocused ? tint : .clear, lineWidth: 2)
                            )
                            .foregroundStyle(isFocused ? .black : .primary)
                            .id(idx)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: viewModel.subtitleSearchFocus) { _, newValue in
                if case .language(let i) = newValue {
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.subtitleSearchState {
        case .idle, .loading:
            centered { ProgressView() }
        case .empty:
            centered { Text("player.subtitle.search.noResults").foregroundStyle(.secondary) }
        case .error(let message):
            centered { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        case .downloading:
            centered {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("player.subtitle.search.downloading").foregroundStyle(.secondary)
                }
            }
        case .results(let results):
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(results.enumerated()), id: \.offset) { idx, info in
                            resultRow(info, focused: viewModel.subtitleSearchFocus == .result(idx))
                                .id(idx)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: viewModel.subtitleSearchFocus) { _, newValue in
                    if case .result(let i) = newValue {
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
                    }
                }
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ info: RemoteSubtitleInfo, focused: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.name ?? info.providerName ?? "Subtitle")
                    .lineLimit(1)
                    .foregroundStyle(focused ? .black : .primary)
                HStack(spacing: 12) {
                    if let provider = info.providerName { Text(provider) }
                    if let lang = info.threeLetterISOLanguageName { Text(lang.uppercased()) }
                    if let fmt = info.format { Text(fmt.uppercased()) }
                }
                .font(.caption)
                .foregroundStyle(focused ? .black.opacity(0.7) : .secondary)
            }
            Spacer()
            if let count = info.downloadCount {
                Label("\(count)", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(focused ? .black.opacity(0.7) : .secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(focused ? tint : Color.white.opacity(0.08))
        )
    }
}
