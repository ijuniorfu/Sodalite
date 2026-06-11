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

            // Live TV probe never throws; run it outside the music do/catch
            // so a music failure cannot prevent the Live TV tab from appearing.
            let hasLive = await dependencies.serverHasLiveTV(userID: userID)
            if hasLive, !availableTabs.contains(.liveTV) {
                if let homeIndex = availableTabs.firstIndex(of: .home) {
                    availableTabs.insert(.liveTV, at: homeIndex + 1)
                } else {
                    availableTabs.insert(.liveTV, at: 0)
                }
            }

            do {
                let hasMusic = try await dependencies.jellyfinMusicService.hasMusicLibrary(userID: userID)
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
            scheduleTabBarWidthFix()
        }
        .onChange(of: iconColor) { _, _ in
            // Re-apply when the user changes their accent in
            // Appearance settings; UITabBarItem.appearance() reads
            // the values at configure time, not live.
            configureTabBarItemAppearance()
        }
        .onChange(of: availableTabs) { _, _ in
            // Live TV / Music tabs arrive async and rebuild the bar's
            // items, which changes the width it needs; re-run the
            // truncation fix against the new layout.
            scheduleTabBarWidthFix()
        }
    }

    /// The system tab bar sizes itself, and on tvOS 26 long localized
    /// titles ("Einstellungen") get truncated instead of widening the
    /// bar. There is no public width API, so after layout settles we
    /// measure whether any item label is actually truncated and widen
    /// the system container's width constraints by exactly the missing
    /// points, capped at the window's safe-area width so the bar can
    /// never run off-screen. Re-run on tab-set changes; a second pass
    /// covers slow first layouts.
    private func scheduleTabBarWidthFix() {
        deferOnMain(by: 0.5) { Self.widenTruncatedTabBars() }
        deferOnMain(by: 2.0) { Self.widenTruncatedTabBars() }
    }

    private static func widenTruncatedTabBars() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                widenTabBarIfTruncated(in: window, window: window)
            }
        }
    }

    private static func widenTabBarIfTruncated(in view: UIView, window: UIWindow) {
        if let tabBar = view as? UITabBar {
            applyWidthFix(to: tabBar, window: window)
        }
        for subview in view.subviews {
            widenTabBarIfTruncated(in: subview, window: window)
        }
    }

    private static func applyWidthFix(to tabBar: UITabBar, window: UIWindow) {
        var labels: [UILabel] = []
        collectLabels(in: tabBar, into: &labels)
        // Item titles only: skip empty/system labels.
        let titled = labels.filter { !($0.text?.isEmpty ?? true) }
        guard !titled.isEmpty else { return }

        let missing = titled.reduce(CGFloat.zero) { sum, label in
            let needed = label.intrinsicContentSize.width - label.bounds.width
            return needed > 0.5 ? sum + needed : sum
        }
        guard missing > 0.5 else { return }

        let safeWidth = window.safeAreaLayoutGuide.layoutFrame.width
        LogTap.shared.note(
            "[TabBar] truncated titles detected, missing=\(Int(missing))pt"
            + " barWidth=\(Int(tabBar.bounds.width)) safeWidth=\(Int(safeWidth))"
        )

        // Widen every adjustable width constraint that currently caps
        // the bar or one of its near ancestors. Required-priority
        // constraints with a fixed constant are the cap the system
        // installs; bump the constant, never past the safe area.
        var node: UIView? = tabBar
        var depth = 0
        var adjusted = false
        while let current = node, depth < 4 {
            for constraint in current.constraints {
                guard constraint.firstAttribute == .width,
                      constraint.secondItem == nil,
                      constraint.constant > 100,
                      (constraint.firstItem as? UIView) === current else { continue }
                let target = min(constraint.constant + missing + 8, safeWidth)
                if target > constraint.constant + 0.5 {
                    LogTap.shared.note(
                        "[TabBar] widening \(type(of: current)) width"
                        + " \(Int(constraint.constant)) -> \(Int(target))"
                        + " (id=\(constraint.identifier ?? "-"))"
                    )
                    constraint.constant = target
                    adjusted = true
                }
            }
            node = current.superview
            depth += 1
        }

        if adjusted {
            tabBar.superview?.setNeedsLayout()
            tabBar.setNeedsLayout()
        } else {
            // Nothing adjustable found: dump the geometry so the next
            // log export tells us which constraint actually caps it.
            var chain: [String] = []
            var probe: UIView? = tabBar
            var level = 0
            while let current = probe, level < 4 {
                let widths = current.constraints
                    .filter { $0.firstAttribute == .width }
                    .map { "\(Int($0.constant))@\(Int($0.priority.rawValue))" }
                    .joined(separator: ",")
                chain.append("\(type(of: current)) w=\(Int(current.bounds.width)) [\(widths)]")
                probe = current.superview
                level += 1
            }
            LogTap.shared.note("[TabBar] no adjustable width constraint; chain: " + chain.joined(separator: " | "))
        }
    }

    private static func collectLabels(in view: UIView, into labels: inout [UILabel]) {
        if let label = view as? UILabel { labels.append(label) }
        for subview in view.subviews {
            collectLabels(in: subview, into: &labels)
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

