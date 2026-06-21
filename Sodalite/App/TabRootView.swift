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
                        // Plain template symbol. tvOS templates tab-bar
                        // SF Symbols regardless, so the accent is applied
                        // via UITabBarItemAppearance.iconColor (see
                        // configureTabBarItemAppearance), not by baking a
                        // fixed .alwaysOriginal image that the tab bar
                        // discards on a mid-session rebuild.
                        Image(systemName: tab.systemImage)
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

            // Probe both optional tabs, then publish the whole tab set in a
            // SINGLE assignment. Inserting Live TV and Music as two separate
            // mutations rebuilt the tab bar twice; the item created in the
            // earlier rebuild (Live TV) got stranded on tvOS's gray icon
            // template while the one created in the later rebuild (Music)
            // picked up the accent. One atomic rebuild means every item is
            // born in the same appearance pass and tints uniformly.
            let hasLive = await dependencies.serverHasLiveTV(userID: userID)
            guard !Task.isCancelled, signal == lastProbedServerSwitch else { return }

            // A music probe failure must not keep the Live TV tab hidden, so
            // swallow its error into a plain false rather than letting it
            // skip the assignment below.
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
            // rebuilds the TabView's UITabBar. The standardAppearance
            // proxy covers the freshly allocated tab bar, but re-apply on
            // the next tick as a belt-and-braces measure in case the new
            // bar exists before the proxy is consulted.
            DispatchQueue.main.async {
                configureTabBarItemAppearance()
            }
            // DIAGNOSTIC: dump the settled tab-bar item state so we can see
            // exactly what is different about the Live TV item (image mode,
            // enabled, applied icon color). Remove once the gray-icon bug
            // is confirmed fixed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                dumpTabBarState(reason: "1.5s after availableTabs change")
            }
        }
    }

    /// Tints the tab bar's icons and titles through `UITabBarAppearance`.
    ///
    /// Why the appearance API and not per-item images: tvOS always
    /// renders tab-bar SF Symbols as templates. Baking an
    /// `.alwaysOriginal` accent image onto each `UITabBarItem` looked
    /// right until the Live TV / Music tabs were inserted mid-session,
    /// which rebuilds the underlying `UITabBar`; tvOS re-templated the
    /// new items gray and discarded the baked image. Titles never had
    /// this problem because they flow through `titleTextAttributes`,
    /// which the framework honors. `iconColor` is the equivalent lever
    /// for symbols: it tells tvOS which color to template TO, so the
    /// accent survives any rebuild.
    ///
    /// Applied two ways: the `UITabBar.appearance()` proxy so a freshly
    /// allocated tab bar (the mid-session rebuild) inherits it, and a
    /// walk of the live window hierarchy so the tab bar currently on
    /// screen repaints immediately (e.g. when the user flips their
    /// accent in Appearance settings).
    private func configureTabBarItemAppearance() {
        let tintUIColor = UIColor(iconColor)

        let itemAppearance = UITabBarItemAppearance()
        // Icons: accent color in every state.
        itemAppearance.normal.iconColor = tintUIColor
        itemAppearance.selected.iconColor = tintUIColor
        itemAppearance.focused.iconColor = tintUIColor
        // Titles: white at rest, accent when selected or focused.
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: tintUIColor]
        itemAppearance.focused.titleTextAttributes = [.foregroundColor: tintUIColor]

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        // tvOS may lay items out stacked or inline depending on width;
        // set all three so the tint holds regardless.
        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        // Future tab bars (a rebuild allocates a new one) inherit this.
        UITabBar.appearance().standardAppearance = appearance

        // Repaint the tab bar that's already on screen.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                Self.applyTabBarAppearance(appearance, in: window)
            }
        }
    }

    private static func applyTabBarAppearance(_ appearance: UITabBarAppearance, in view: UIView) {
        if let tabBar = view as? UITabBar {
            tabBar.standardAppearance = appearance
            // View-level tint as well. unselectedItemTintColor cascades and
            // re-tints every unselected template icon on the spot, including
            // an item that the per-item appearance left stranded on tvOS's
            // gray template. tintColor covers the selected/focused icon.
            tabBar.tintColor = appearance.stackedLayoutAppearance.selected.iconColor
            tabBar.unselectedItemTintColor = appearance.stackedLayoutAppearance.normal.iconColor
            // Per-item override too. The bar-level appearance alone does
            // not re-color an item that was already rendered gray before
            // the appearance was applied. Forcing each item's own
            // standardAppearance makes every item re-adopt the tint
            // regardless of when it was created.
            for item in tabBar.items ?? [] {
                item.standardAppearance = appearance
            }
        }
        for subview in view.subviews {
            applyTabBarAppearance(appearance, in: subview)
        }
    }

    // MARK: - Diagnostics (temporary)

    /// Dumps every live UITabBar item's render-relevant state into the
    /// in-app log (Support screen) and the console, so we can pinpoint why
    /// the Live TV icon renders gray while its siblings tint correctly.
    private func dumpTabBarState(reason: String) {
        var lines = ["[TabBarDiag] \(reason); availableTabs=\(availableTabs.map(\.rawValue))"]
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                Self.collectTabBarState(in: window, into: &lines)
            }
        }
        let dump = lines.joined(separator: "\n")
        LogTap.shared.note(dump)
        print(dump)
    }

    private static func collectTabBarState(in view: UIView, into lines: inout [String]) {
        if let tabBar = view as? UITabBar {
            lines.append(
                "[TabBarDiag] UITabBar items=\(tabBar.items?.count ?? 0) "
                + "tint=\(describe(tabBar.tintColor)) "
                + "unselectedTint=\(tabBar.unselectedItemTintColor.map(describe) ?? "nil") "
                + "barStandardAppearance=\(tabBar.standardAppearance != nil ? "set" : "nil")"
            )
            for (index, item) in (tabBar.items ?? []).enumerated() {
                let image = item.image
                let mode = image.map { "\($0.renderingMode.rawValue)" } ?? "nilImage"
                let itemIconColor = item.standardAppearance?
                    .stackedLayoutAppearance.normal.iconColor
                    .map(describe) ?? "noItemAppearance"
                lines.append(
                    "[TabBarDiag]  [\(index)] title=\(item.title ?? "nil") "
                    + "enabled=\(item.isEnabled) imgRenderMode=\(mode) "
                    + "itemNormalIconColor=\(itemIconColor) "
                    + "img=\(image?.description ?? "nil")"
                )
            }
        }
        for subview in view.subviews {
            collectTabBarState(in: subview, into: &lines)
        }
    }

    private static func describe(_ color: UIColor?) -> String {
        guard let color else { return "nil" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a)
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

