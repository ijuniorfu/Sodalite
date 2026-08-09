import SwiftUI

/// Sodalite#62: pick which tabs the navigation bar shows. Home and Settings are not listed, they are
/// the landing tab and the only route back to this screen. Live TV and Music stay listed even when
/// the active server offers neither: rows appearing under the focused one is a tvOS focus hazard,
/// and their subtitles say the server has the last word.
struct TabVisibilitySettingsView: View {
    @Environment(\.dependencies) private var dependencies

    private var appearance: AppearancePreferences { dependencies.appearancePreferences }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.bottom, 8)

                Text("settings.tabs.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                ForEach(AppTab.hideableCases, id: \.self) { tab in
                    ValuePickerRow(
                        icon: tab.systemImage,
                        title: tab.labelKey,
                        subtitle: subtitleKey(for: tab),
                        options: [false, true],
                        selection: Binding(
                            get: { !appearance.isTabHidden(tab) },
                            set: { appearance.setTab(tab, hidden: !$0) }
                        ),
                        label: { visible in
                            visible
                                ? String(localized: "settings.playback.on", defaultValue: "On")
                                : String(localized: "settings.playback.off", defaultValue: "Off")
                        }
                    )
                }

                Text("settings.tabs.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
            .screenContentInset()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .hidesShellTabBar()
        // Suppress the floating tvOS nav-title; the inline header below is the screen's own.
        .hidesNavigationBarChrome()
    }

    private var header: some View {
        Text("settings.tabs.title")
            .font(.largeTitle)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
    }

    private func subtitleKey(for tab: AppTab) -> LocalizedStringKey {
        switch tab {
        case .liveTV: "settings.tabs.liveTV.subtitle"
        case .catalog: "settings.tabs.catalog.subtitle"
        case .search: "settings.tabs.search.subtitle"
        case .music: "settings.tabs.music.subtitle"
        case .home, .settings: ""
        }
    }
}
