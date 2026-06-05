import SwiftUI
import UIKit

enum AppTab: String, CaseIterable, Sendable {
    case home
    case catalog
    case search
    case music
    case settings

    var labelKey: LocalizedStringKey {
        switch self {
        case .home: "tab.home"
        case .catalog: "tab.catalog"
        case .search: "tab.search"
        case .music: "tab.music"
        case .settings: "tab.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .catalog: "film.stack"
        case .search: "magnifyingglass"
        case .music: "music.note"
        case .settings: "gearshape"
        }
    }
}

struct TabRootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var availableTabs: [AppTab] = AppTab.allCases.filter { $0 != .music }
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
            ForEach(availableTabs, id: \.self) { tab in
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
        // Siri Remote play/pause button while browsing (foreground): it is
        // delivered to the responder chain, not MPRemoteCommandCenter, so
        // toggle music here when a track is active.
        .onPlayPauseCommand {
            let coordinator = dependencies.musicPlaybackCoordinator
            if coordinator.currentItem != nil {
                LogTap.shared.note("[NowPlaying] onPlayPauseCommand (tab bar, in-app)")
                coordinator.togglePlayPause()
            }
        }
        .task {
            guard let userID = dependencies.activeUserID else { return }
            do {
                let hasMusic = try await dependencies.jellyfinMusicService.hasMusicLibrary(userID: userID)
                if hasMusic, !availableTabs.contains(.music) {
                    // Insert Music before Settings so the order is:
                    // Home, Catalog, Search, Music, Settings.
                    if let settingsIndex = availableTabs.firstIndex(of: .settings) {
                        availableTabs.insert(.music, at: settingsIndex)
                    } else {
                        availableTabs.append(.music)
                    }
                }
            } catch {
                // No music library confirmed; tab stays hidden.
            }
        }
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
    /// proxy AND walks the active window's existing UITabBar instances
    /// to update them in place. The proxy alone only affects future
    /// `UITabBarItem` constructions; existing items (the live tab bar
    /// the user is looking at) keep whatever attributes they had at
    /// construction time. That's the "tab text shows the previous
    /// accent color until app restart" symptom — accent flips in
    /// Settings → effectiveTint changes → onChange fires → proxy
    /// updates but the visible tab bar doesn't repaint because its
    /// items were created with the old proxy values.
    ///
    /// Live update: walk every UIWindow's view hierarchy, find any
    /// UITabBar, and set the title attributes on each of its items
    /// for all relevant states. Cheap (one TabRootView in the app, ~4
    /// items each, runs only on accent change and initial appear).
    private func configureTabBarItemAppearance() {
        let tintUIColor = UIColor(iconColor)
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.white
        ]
        let selectedAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: tintUIColor
        ]

        // Future instances pick up new values from the proxy.
        let proxy = UITabBarItem.appearance()
        proxy.setTitleTextAttributes(normalAttrs, for: .normal)
        proxy.setTitleTextAttributes(selectedAttrs, for: .selected)
        proxy.setTitleTextAttributes(selectedAttrs, for: .focused)
        proxy.setTitleTextAttributes(selectedAttrs, for: [.selected, .focused])

        // Existing items need explicit per-instance updates because
        // the proxy doesn't retroactively rewrite already-allocated
        // UITabBarItem attribute dictionaries.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                Self.applyTabBarItemAttributes(
                    in: window,
                    normal: normalAttrs,
                    selected: selectedAttrs
                )
            }
        }
    }

    private static func applyTabBarItemAttributes(
        in view: UIView,
        normal: [NSAttributedString.Key: Any],
        selected: [NSAttributedString.Key: Any]
    ) {
        if let tabBar = view as? UITabBar {
            for item in tabBar.items ?? [] {
                item.setTitleTextAttributes(normal, for: .normal)
                item.setTitleTextAttributes(selected, for: .selected)
                item.setTitleTextAttributes(selected, for: .focused)
                item.setTitleTextAttributes(selected, for: [.selected, .focused])
            }
        }
        for subview in view.subviews {
            applyTabBarItemAttributes(in: subview, normal: normal, selected: selected)
        }
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
        case .music:
            MusicHomeView()
        case .settings:
            SettingsView()
        }
    }
}

