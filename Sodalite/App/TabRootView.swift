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

    /// Resolved tab-bar title for the UIKit shell, which needs a `String` (not SwiftUI's `LocalizedStringKey`).
    var titleString: String {
        switch self {
        case .home: String(localized: "tab.home")
        case .liveTV: String(localized: "tab.liveTV")
        case .catalog: String(localized: "tab.catalog")
        case .search: String(localized: "tab.search")
        case .music: String(localized: "tab.music")
        case .settings: String(localized: "tab.settings")
        }
    }
}

struct TabRootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var availableTabs: [AppTab] = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
    /// serverDidSwitch value of the last completed tab probe. -1 so the first probe fires; a `.task` re-fire on reappear is a no-op while a real switch re-probes.
    @State private var lastProbedServerSwitch = -1
    /// Re-probe triggered by .loginDidComplete (add-server / add-profile authenticates via setAuthenticated WITHOUT bumping serverDidSwitch, so the serverDidSwitch probe never fires for the new server).
    @State private var loginProbeTask: Task<Void, Never>?
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    /// Tab-bar icon accent; falls back to the asset-catalog accent on `.system` so icons never render plain white.
    private var iconColor: Color {
        dependencies.appearancePreferences.effectiveTint(
            isSupporter: dependencies.storeKitService.isSupporter
        ) ?? Color.accentColor
    }

    var body: some View {
        // UIKit tab-bar shell (not SwiftUI TabView): the per-tab content controllers persist across the tab-bar hide/show a detail performs, so the bar can be re-tinted or rebuilt without reloading any tab. See RootTabBarView.
        RootTabBarView(
            selectedTab: $selectedTab,
            availableTabs: availableTabs,
            iconColor: iconColor,
            content: { tab in AnyView(tabContent(for: tab).tint(iconColor)) }
        )
        .ignoresSafeArea()
        // Display-only active-profile badge; non-focusable, below the player cover, hidden unless the server has multiple profiles.
        .overlay(alignment: .topTrailing) {
            ActiveUserBadge()
        }
        // Foreground Siri Remote play/pause arrives via the responder chain (not MPRemoteCommandCenter), so toggle music here when a track is active.
        .onPlayPauseCommand {
            let coordinator = dependencies.musicPlaybackCoordinator
            if coordinator.currentItem != nil {
                LogTap.shared.note("[NowPlaying] onPlayPauseCommand (tab bar, in-app)")
                coordinator.togglePlayPause()
            }
        }
        .task(id: appState.serverDidSwitch) {
            // TabRootView stays mounted across a switch, so recompute the optional Live TV / Music tabs per server, else the old server's Live TV lingers (wrong backend) and a new server's Music never appears until relaunch.
            let signal = appState.serverDidSwitch
            guard signal != lastProbedServerSwitch else { return }
            let isServerSwitch = lastProbedServerSwitch != -1
            let previousSignal = lastProbedServerSwitch
            lastProbedServerSwitch = signal
            // Latch up front against re-entrant double-probe, but give it back on cancellation (view disappears mid-probe), else the reappear re-fire hits the guard and the Live TV / Music tabs stay missing for the session.
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

            // Probe both optional tabs then publish the tab set in ONE assignment. Two separate insertions rebuilt the bar twice, stranding the earlier item (Live TV) on tvOS's gray icon template; one atomic rebuild tints every item uniformly.
            let hasLive = await dependencies.serverHasLiveTV(userID: userID)
            guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }

            // Swallow a music-probe error into false so it doesn't skip the assignment and leave Live TV hidden.
            var hasMusic = false
            do {
                hasMusic = try await dependencies.jellyfinMusicService.hasMusicLibrary(userID: userID)
            } catch {
                // No music library confirmed; tab stays hidden.
            }
            guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }

            // Order: Home, [Live TV,] Catalog, Search, [Music,] Settings.
            var tabs = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
            if hasLive, let homeIndex = tabs.firstIndex(of: .home) {
                tabs.insert(.liveTV, at: homeIndex + 1)
            }
            if hasMusic, let settingsIndex = tabs.firstIndex(of: .settings) {
                tabs.insert(.music, at: settingsIndex)
            }
            if tabs != availableTabs {
                availableTabs = tabs
            }
        }
        // Adding a server (or another profile) authenticates through LoginView -> setAuthenticated, which changes the active server WITHOUT bumping serverDidSwitch, so the probe above never re-fires for the new backend. Re-probe here, else the previous server's Live TV / Music tabs linger and tapping a Live TV tab on a server without Live TV crashes.
        .onReceive(NotificationCenter.default.publisher(for: .loginDidComplete)) { _ in
            loginProbeTask?.cancel()
            loginProbeTask = Task { await recomputeOptionalTabsAfterLogin() }
        }
    }

    /// Re-evaluates the optional Live TV / Music tabs for the now-active server after a login completion. Drops the previous server's optional tabs first (so a stale, crash-prone Live TV tab is gone immediately), then probes the new backend and republishes. Mirrors the serverDidSwitch probe; kept separate so that device-verified path stays untouched.
    @MainActor
    private func recomputeOptionalTabsAfterLogin() async {
        let base = AppTab.allCases.filter { $0 != .music && $0 != .liveTV }
        availableTabs = base
        if !base.contains(selectedTab) {
            selectedTab = .home
        }
        guard let userID = dependencies.activeUserID else { return }

        let hasLive = await dependencies.serverHasLiveTV(userID: userID)
        if Task.isCancelled { return }
        var hasMusic = false
        do {
            hasMusic = try await dependencies.jellyfinMusicService.hasMusicLibrary(userID: userID)
        } catch {
            // No music library confirmed; tab stays hidden.
        }
        if Task.isCancelled { return }

        var tabs = base
        if hasLive, let homeIndex = tabs.firstIndex(of: .home) {
            tabs.insert(.liveTV, at: homeIndex + 1)
        }
        if hasMusic, let settingsIndex = tabs.firstIndex(of: .settings) {
            tabs.insert(.music, at: settingsIndex)
        }
        if tabs != availableTabs {
            availableTabs = tabs
        }
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

