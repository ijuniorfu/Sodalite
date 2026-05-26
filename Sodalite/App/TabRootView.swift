import SwiftUI
import UIKit

enum AppTab: String, CaseIterable, Sendable {
    case home
    case catalog
    case search
    case settings

    var labelKey: LocalizedStringKey {
        switch self {
        case .home: "tab.home"
        case .catalog: "tab.catalog"
        case .search: "tab.search"
        case .settings: "tab.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .catalog: "film.stack"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

struct TabRootView: View {
    @State private var selectedTab: AppTab = .home
    @Environment(\.dependencies) private var dependencies

    /// Resolved accent color for the tab-bar icons. Falls back to the
    /// asset-catalog accent when the user is on `.system`, so the icons
    /// never render as plain white.
    private var iconColor: Color {
        dependencies.appearancePreferences.effectiveTint(
            isSupporter: dependencies.storeKitService.isSupporter
        ) ?? Color.accentColor
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(value: tab) {
                    tabContent(for: tab)
                } label: {
                    Label {
                        Text(tab.labelKey)
                    } icon: {
                        // tvOS re-tints SF Symbols inside Tab labels,
                        // ignoring SwiftUI's .foregroundStyle. Baking the
                        // color into a UIImage with .alwaysOriginal is
                        // the only rendering mode the tab bar respects.
                        tabIcon(name: tab.systemImage, color: iconColor)
                    }
                }
            }
        }
        .tint(iconColor)
        .onAppear {
            configureTabBarItemAppearance()
        }
        .onChange(of: iconColor) { _, _ in
            // Re-apply when the user changes their accent in
            // Appearance settings; UITabBarItem.appearance() reads
            // the values at configure time, not live.
            configureTabBarItemAppearance()
        }
    }

    /// Drives the tab bar's per-state text color via UIKit's appearance
    /// proxy. All states render white — selection / focus is indicated
    /// by the system's focus pill background, not by tinting the text.
    /// Tinting the text on the selected / focused state left the
    /// previously-focused tab stuck in tint after focus moved away
    /// ("der text hat immer die zuletzt ausgewählte farbe" report
    /// 2026-05-26 from Vincent's Samsung), because tvOS UITabBar
    /// doesn't reliably revert state-keyed attributes when focus
    /// leaves an item. Forcing white on every state ([.normal,
    /// .selected, .focused, [.selected, .focused]]) eliminates the
    /// state-machine race entirely; the pill is the only selection
    /// indicator the UX needs.
    private func configureTabBarItemAppearance() {
        let whiteAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.white
        ]
        let appearance = UITabBarItem.appearance()
        appearance.setTitleTextAttributes(whiteAttrs, for: .normal)
        appearance.setTitleTextAttributes(whiteAttrs, for: .selected)
        appearance.setTitleTextAttributes(whiteAttrs, for: .focused)
        appearance.setTitleTextAttributes(whiteAttrs, for: [.selected, .focused])
    }

    private func tabIcon(name: String, color: Color) -> Image {
        // Match the native tvOS tab-bar symbol weight/size. Without an
        // explicit configuration, UIImage(systemName:) falls back to a
        // smaller default than the tab bar would request for a raw
        // SwiftUI Image, the icons end up visibly shrunken.
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let base = UIImage(systemName: name, withConfiguration: config)
            ?? UIImage(systemName: name)
        guard let symbol = base else {
            return Image(systemName: name)
        }
        let tinted = symbol.withTintColor(
            UIColor(color),
            renderingMode: .alwaysOriginal
        )
        return Image(uiImage: tinted)
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()
        case .catalog:
            CatalogView()
        case .search:
            SearchView()
        case .settings:
            SettingsView()
        }
    }
}

