import SwiftUI
import UIKit

/// UIKit tab-bar shell. Replaces SwiftUI `TabView` so the tab content controllers persist across the tab-bar hide/show a detail performs: SwiftUI's `TabView` couples bar identity to content identity, so the only way to get a freshly-tinted bar (tvOS will not re-tint a reused one) was to rebuild the whole TabView, which reloaded every tab. Here each tab is a cached `UIHostingController`, so the bar can be hidden/shown (or rebuilt) without touching content.
///
/// Immersion (hiding the bar inside a detail) is driven by `.hidesShellTabBar()` posting a depth delta, NOT by SwiftUI's `.toolbar(.hidden, for: .tabBar)` (which only targets a SwiftUI `TabView`, absent here).
struct RootTabBarView: UIViewControllerRepresentable {
    @Binding var selectedTab: AppTab
    let availableTabs: [AppTab]
    let iconColor: Color
    /// Builds the SwiftUI content for a tab. Read app state via the `\.appState` / `\.dependencies` environment defaults (shared singletons), so the hosted views need no explicit environment injection.
    let content: (AppTab) -> AnyView

    func makeUIViewController(context: Context) -> ShellTabBarController {
        let controller = ShellTabBarController()
        controller.onSelect = { context.coordinator.select($0) }
        controller.apply(tabs: availableTabs, selected: selectedTab, iconColor: UIColor(iconColor), content: content)
        return controller
    }

    func updateUIViewController(_ controller: ShellTabBarController, context: Context) {
        context.coordinator.parent = self
        controller.onSelect = { context.coordinator.select($0) }
        controller.apply(tabs: availableTabs, selected: selectedTab, iconColor: UIColor(iconColor), content: content)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: RootTabBarView
        init(_ parent: RootTabBarView) { self.parent = parent }
        func select(_ tab: AppTab) {
            if parent.selectedTab != tab { parent.selectedTab = tab }
        }
    }
}

/// Container hosting a child `UITabBarController`. The container is what SwiftUI retains, so the child bar can be rebuilt (fresh, correctly tinted) while the cached content controllers are re-parented intact.
final class ShellTabBarController: UIViewController, UITabBarControllerDelegate {
    var onSelect: ((AppTab) -> Void)?

    private var tabController = UITabBarController()
    /// One hosting controller per tab, reused across rebuilds so tab content (and its SwiftUI navigation/scroll state) survives a bar hide/show or rebuild.
    private var hosts: [AppTab: UIHostingController<AnyView>] = [:]
    private var orderedTabs: [AppTab] = []
    private var iconColor: UIColor = .white
    /// Last accent applied; gates the (otherwise per-update) appearance + rootView refresh so a normal re-render does not churn every tab's content.
    private var appliedIconColor: UIColor?
    /// Nesting-safe immersion counter: >0 while any detail that called `.hidesShellTabBar()` is on screen.
    private var immersionDepth = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        // App is dark-only; SodaliteApp sets .preferredColorScheme(.dark) at the SwiftUI root, but a freshly created hosting/tab controller does not inherit it, so pin it here (propagates to the child tab bar + all hosted content).
        overrideUserInterfaceStyle = .dark
        tabController.delegate = self
        addChild(tabController)
        tabController.view.frame = view.bounds
        tabController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tabController.view)
        tabController.didMove(toParent: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(immersionChanged(_:)),
            name: .shellTabBarImmersion,
            object: nil
        )
    }

    func apply(tabs: [AppTab], selected: AppTab, iconColor color: UIColor, content: (AppTab) -> AnyView) {
        iconColor = color
        // Only do appearance + content work when the accent actually changed (or on first apply); a routine re-render must not churn every tab's rootView.
        let colorChanged = appliedIconColor != color
        if colorChanged {
            appliedIconColor = color
            applyAppearance()
        }

        var viewControllers: [UIViewController] = []
        for tab in tabs {
            let host: UIHostingController<AnyView>
            if let existing = hosts[tab] {
                host = existing
                // Refresh only on accent change (the rootView bakes in `.tint`); SwiftUI diffs against retained @State, so even then the tab is not reset.
                if colorChanged { host.rootView = content(tab) }
            } else {
                host = UIHostingController(rootView: content(tab))
                host.view.backgroundColor = .clear
                hosts[tab] = host
            }
            host.tabBarItem = UITabBarItem(
                title: tab.titleString,
                image: Self.tabIcon(tab.systemImage),
                selectedImage: Self.tabIcon(tab.systemImage)
            )
            viewControllers.append(host)
        }
        for key in Array(hosts.keys) where !tabs.contains(key) {
            hosts.removeValue(forKey: key)
        }

        if orderedTabs != tabs {
            tabController.setViewControllers(viewControllers, animated: false)
            orderedTabs = tabs
            // The new bar's items must read the tinted appearance.
            applyAppearance()
        }
        if let index = tabs.firstIndex(of: selected), tabController.selectedIndex != index {
            tabController.selectedIndex = index
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        let index = tabBarController.selectedIndex
        guard orderedTabs.indices.contains(index) else { return }
        onSelect?(orderedTabs[index])
    }

    @objc private func immersionChanged(_ note: Notification) {
        let delta = (note.userInfo?[ShellImmersionKey.delta] as? Int) ?? 0
        immersionDepth = max(0, immersionDepth + delta)
        let shouldHide = immersionDepth > 0
        guard tabController.tabBar.isHidden != shouldHide else { return }
        tabController.tabBar.isHidden = shouldHide
        if !shouldHide {
            // Returned to a tab root. Re-assert the appearance; if tvOS still renders the re-shown bar gray, the fresh-bar rebuild is the fallback (see rebuildTabBar()).
            applyAppearance()
        }
    }

    /// Fallback for a re-shown bar that tvOS refuses to re-tint: build a brand-new child `UITabBarController` and move the cached content controllers into it. A fresh `UITabBar` reads the tinted appearance at creation; content state survives because the hosting controllers are reused.
    func rebuildTabBar() {
        let selectedIndex = tabController.selectedIndex
        let viewControllers = tabController.viewControllers ?? []

        tabController.willMove(toParent: nil)
        tabController.view.removeFromSuperview()
        tabController.removeFromParent()

        let fresh = UITabBarController()
        fresh.delegate = self
        for vc in viewControllers { vc.removeFromParent() }
        fresh.setViewControllers(viewControllers, animated: false)
        if viewControllers.indices.contains(selectedIndex) {
            fresh.selectedIndex = selectedIndex
        }
        addChild(fresh)
        fresh.view.frame = view.bounds
        fresh.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(fresh.view)
        fresh.didMove(toParent: self)
        tabController = fresh
        applyAppearance()
    }

    private func applyAppearance() {
        let item = UITabBarItemAppearance()
        item.normal.iconColor = iconColor
        item.selected.iconColor = iconColor
        item.focused.iconColor = iconColor
        item.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
        item.selected.titleTextAttributes = [.foregroundColor: iconColor]
        item.focused.titleTextAttributes = [.foregroundColor: iconColor]

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        tabController.tabBar.standardAppearance = appearance
    }

    /// Monochrome template symbol; mirrors the SwiftUI `.symbolRenderingMode(.monochrome)` fix so the `tv` symbol's baked hierarchical color does not override the icon tint.
    private static func tabIcon(_ name: String) -> UIImage? {
        let config = UIImage.SymbolConfiguration.preferringMonochrome()
        return UIImage(systemName: name, withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
    }
}

// MARK: - Immersion signal

enum ShellImmersionKey {
    static let delta = "delta"
}

extension View {
    /// Hides the shell's tab bar while this view is on screen (detail immersion). Replaces `.toolbar(.hidden, for: .tabBar)` for views shown inside `RootTabBarView`; keeps the SwiftUI call too in case a SwiftUI `TabView` is ever an ancestor.
    func hidesShellTabBar() -> some View {
        self
            .toolbar(.hidden, for: .tabBar)
            .modifier(ShellImmersionModifier())
    }
}

private struct ShellImmersionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                NotificationCenter.default.post(
                    name: .shellTabBarImmersion, object: nil, userInfo: [ShellImmersionKey.delta: 1]
                )
            }
            .onDisappear {
                NotificationCenter.default.post(
                    name: .shellTabBarImmersion, object: nil, userInfo: [ShellImmersionKey.delta: -1]
                )
            }
    }
}
