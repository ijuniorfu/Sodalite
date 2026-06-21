import SwiftUI
import UIKit

enum AppTab: String, CaseIterable, Sendable {
    case home
    case liveTV
    case catalog
    case search
    case music
    case settings

    var labelKey: LocalizedStringKey {
        switch self {
        case .home: "tab.home"
        case .liveTV: "tab.liveTV"
        case .catalog: "tab.catalog"
        case .search: "tab.search"
        case .music: "tab.music"
        case .settings: "tab.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .liveTV: "tv"
        case .catalog: "film.stack"
        case .search: "magnifyingglass"
        case .music: "music.note"
        case .settings: "gearshape"
        }
    }
}

struct TabRootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var availableTabs: [AppTab] = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
    /// serverDidSwitch value of the last completed tab probe. -1 until
    /// the first probe so the initial run always fires; afterwards a
    /// `.task` re-fire from a view reappearance is a no-op while a real
    /// server switch (different signal value) resets and re-probes.
    @State private var lastProbedServerSwitch = -1
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

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
        // Display-only active-profile badge in the top-trailing corner.
        // Non-focusable, so it never intercepts focus from the nav bar;
        // sits below the player fullScreenCover, so it's absent during
        // playback. Hidden unless the server has multiple profiles.
        .overlay(alignment: .topTrailing) {
            ActiveUserBadge()
        }
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
        .task(id: appState.serverDidSwitch) {
            // TabRootView stays mounted across a server switch, so the
            // Live TV / Music tabs have to be recomputed per server:
            // otherwise the old server's Live TV tab lingers (querying
            // the wrong backend) and a new server's Music tab never
            // appears until app relaunch.
            let signal = appState.serverDidSwitch
            guard signal != lastProbedServerSwitch else { return }
            let isServerSwitch = lastProbedServerSwitch != -1
            let previousSignal = lastProbedServerSwitch
            lastProbedServerSwitch = signal
            // The latch is taken up front so a re-entrant fire of the
            // same signal can't double-probe, but a cancelled run (view
            // disappears mid-probe) must give the latch back: the .task
            // re-fires with the same signal on reappear, and without the
            // rollback that re-fire would hit the guard above and the
            // Live TV / Music tabs would stay missing for the session.
            defer {
                if Task.isCancelled, lastProbedServerSwitch == signal {
                    lastProbedServerSwitch = previousSignal
                }
            }
            if isServerSwitch {
                let base = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
                availableTabs = base
                if !base.contains(selectedTab) {
                    selectedTab = .home
                }
            }

            guard let userID = dependencies.activeUserID else { return }

            // Live TV probe never throws; run it outside the music do/catch
            // so a music failure cannot prevent the Live TV tab from appearing.
            let hasLive = await dependencies.serverHasLiveTV(userID: userID)
            guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }
            if hasLive, !availableTabs.contains(.liveTV) {
                if let homeIndex = availableTabs.firstIndex(of: .home) {
                    availableTabs.insert(.liveTV, at: homeIndex + 1)
                } else {
                    availableTabs.insert(.liveTV, at: 0)
                }
            }

            do {
                let hasMusic = try await dependencies.jellyfinMusicService.hasMusicLibrary(userID: userID)
                guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }
                if hasMusic, !availableTabs.contains(.music) {
                    // Insert Music before Settings so the order is:
                    // Home, [Live TV,] Catalog, Search, Music, Settings.
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
        .onChange(of: availableTabs) { _, _ in
            // The Live TV / Music tabs are inserted asynchronously after
            // the server probe completes (see the .task above), which
            // rebuilds the TabView's UITabBarItems. tvOS drops the baked
            // `.alwaysOriginal` icon on that rebuild and falls back to its
            // gray template rendering, the icons go gray until the user
            // re-selects a tab. The new items don't exist yet at this
            // point in the runloop, so re-apply on the next tick once the
            // tab bar has reconstructed.
            DispatchQueue.main.async {
                configureTabBarItemAppearance()
            }
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

        // Baked icon images in availableTabs order. The tab bar's item
        // order mirrors availableTabs, so we can apply them positionally
        // in the hierarchy walk below. Same reasoning as the title
        // attributes: SwiftUI's Tab label sets the image at construction,
        // but a mid-session rebuild (Live TV / Music tabs appearing) lets
        // tvOS re-template the icon gray. Forcing the `.alwaysOriginal`
        // image back onto each live item restores the accent color.
        let icons = availableTabs.map { tintedSymbolImage(name: $0.systemImage, color: iconColor) }

        // Existing items need explicit per-instance updates because
        // the proxy doesn't retroactively rewrite already-allocated
        // UITabBarItem attribute dictionaries.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                Self.applyTabBarItemAttributes(
                    in: window,
                    normal: normalAttrs,
                    selected: selectedAttrs,
                    icons: icons
                )
            }
        }
    }

    private static func applyTabBarItemAttributes(
        in view: UIView,
        normal: [NSAttributedString.Key: Any],
        selected: [NSAttributedString.Key: Any],
        icons: [UIImage?]
    ) {
        if let tabBar = view as? UITabBar {
            for (index, item) in (tabBar.items ?? []).enumerated() {
                item.setTitleTextAttributes(normal, for: .normal)
                item.setTitleTextAttributes(selected, for: .selected)
                item.setTitleTextAttributes(selected, for: .focused)
                item.setTitleTextAttributes(selected, for: [.selected, .focused])
                if index < icons.count, let icon = icons[index] {
                    item.image = icon
                    item.selectedImage = icon
                }
            }
        }
        for subview in view.subviews {
            applyTabBarItemAttributes(in: subview, normal: normal, selected: selected, icons: icons)
        }
    }

    /// Builds the accent-tinted tab-bar symbol as a UIImage with
    /// `.alwaysOriginal` rendering, the only mode the tvOS tab bar
    /// respects (it otherwise re-tints SF Symbols to its gray template).
    /// Shared by the SwiftUI Tab label and the live UIKit item walk.
    private func tintedSymbolImage(name: String, color: Color) -> UIImage? {
        // Match the native tvOS tab-bar symbol weight/size. Without an
        // explicit configuration, UIImage(systemName:) falls back to a
        // smaller default than the tab bar would request for a raw
        // SwiftUI Image, the icons end up visibly shrunken.
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let base = UIImage(systemName: name, withConfiguration: config)
            ?? UIImage(systemName: name)
        guard let symbol = base else { return nil }
        return symbol.withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
    }

    private func tabIcon(name: String, color: Color) -> Image {
        guard let tinted = tintedSymbolImage(name: name, color: color) else {
            return Image(systemName: name)
        }
        return Image(uiImage: tinted)
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()
        case .liveTV:
            LiveTVTabView()
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

