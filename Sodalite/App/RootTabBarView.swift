import SwiftUI
import UIKit

/// UIKit tab-bar shell. Replaces SwiftUI `TabView` so the tab content controllers persist across the tab-bar hide/show a detail performs: SwiftUI's `TabView` couples bar identity to content identity, so the only way to get a freshly-tinted bar (tvOS will not re-tint a reused one) was to rebuild the whole TabView, which reloaded every tab. Here each tab is a cached `UIHostingController`, so the bar can be hidden/shown (or rebuilt) without touching content.
///
/// Immersion (hiding the bar inside a detail) is driven by `.hidesShellTabBar()` posting a per-view token, NOT by SwiftUI's `.toolbar(.hidden, for: .tabBar)` (which only targets a SwiftUI `TabView`, absent here).
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

/// `UITabBarController` whose default/initial focus falls back to the tab bar when the selected content has no focusable item yet (cold launch, content still loading). The focus engine walks `preferredFocusEnvironments` in order and uses the first that yields a focusable item, so content keeps priority once it is ready while the bar stays the reachable default during load. SwiftUI's TabView gave this for free; the raw-UIKit shell otherwise drove initial focus into the empty Home host and left the bar unreachable until the first row materialized.
final class ShellChildTabBarController: UITabBarController {
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        super.preferredFocusEnvironments + [tabBar]
    }
}

/// Container hosting a child `UITabBarController`. The container is what SwiftUI retains, so the child bar can be rebuilt (fresh, correctly tinted) while the cached content controllers are re-parented intact.
final class ShellTabBarController: UIViewController, UITabBarControllerDelegate {
    var onSelect: ((AppTab) -> Void)?

    private var tabController: UITabBarController = ShellChildTabBarController()
    /// One hosting controller per tab, reused across rebuilds so tab content (and its SwiftUI navigation/scroll state) survives a bar hide/show or rebuild.
    private var hosts: [AppTab: UIHostingController<AnyView>] = [:]
    private var orderedTabs: [AppTab] = []
    private var iconColor: UIColor = .white
    /// Last accent applied; gates the (otherwise per-update) appearance + rootView refresh so a normal re-render does not churn every tab's content.
    private var appliedIconColor: UIColor?
    /// Stable per-view immersion tokens; the bar is hidden iff non-empty. A Set (idempotent insert), NOT an Int counter: SwiftUI re-fires onAppear when a child `.sheet`/`.fullScreenCover` dismisses without a matching onDisappear, which drifted the old +1/-1 counter positive and left the bar stuck hidden after back-out (device-confirmed).
    private var immersionTokens: Set<UUID> = []

    override func viewDidLoad() {
        super.viewDidLoad()
        // App is dark-only; SodaliteApp sets .preferredColorScheme(.dark) at the SwiftUI root, but a freshly created hosting/tab controller does not inherit it, so pin it here (propagates to the child tab bar + all hosted content).
        overrideUserInterfaceStyle = .dark
        // Dark fill on the backing layers BEHIND the hosted content so the UITabBarController's tab cross-fade never flashes the white window backing through a translucent (glass) page. NOT isOpaque, and NOT on the host itself: the host stays .clear so a page's .regularMaterial still composites as glass over this dark root (isOpaque flattens the material to dead black).
        view.backgroundColor = .black
        tabController.delegate = self
        addChild(tabController)
        tabController.view.frame = view.bounds
        tabController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tabController.view.backgroundColor = .black
        view.addSubview(tabController.view)
        tabController.didMove(toParent: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(immersionChanged(_:)),
            name: .shellTabBarImmersion,
            object: nil
        )
    }

    /// Route the container's default-focus search into the child tab controller, which applies its content-then-bar fallback order (see ShellChildTabBarController).
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [tabController]
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
                // Clear, NOT opaque black: a page's own .regularMaterial must composite as glass over the dark backing layers behind this host; an opaque black host flattens it to dead black. White-flash prevention lives on those backing layers, not here.
                host.view.backgroundColor = .clear
                // Tab item set once at creation: the icon size is baked into the image and the tint comes from appearance.iconColor, not the image, so a plain tab switch must not rebuild every item.
                host.tabBarItem = UITabBarItem(
                    title: tab.titleString,
                    image: Self.tabIcon(tab.systemImage),
                    selectedImage: Self.tabIcon(tab.systemImage)
                )
                hosts[tab] = host
            }
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
        guard let token = note.userInfo?[ShellImmersionKey.token] as? UUID,
              let active = note.userInfo?[ShellImmersionKey.active] as? Bool else { return }
        let wasImmersed = !immersionTokens.isEmpty
        if active {
            immersionTokens.insert(token)   // idempotent: a repeated onAppear is a no-op, so the set cannot drift
        } else {
            immersionTokens.remove(token)   // no-op for an unknown token, so a stray onDisappear cannot underflow
        }
        let isImmersed = !immersionTokens.isEmpty
        guard wasImmersed != isImmersed else { return }
        if isImmersed {
            // Hiding via isHidden is the reliable direction.
            tabController.tabBar.isHidden = true
        } else {
            // Back at a tab root. isHidden=false does NOT reliably re-show, and re-greys, a reused UITabBarController bar (device-confirmed), so rebuild a fresh child controller: a new UITabBar is visible and reads the tinted appearance at creation; cached content controllers are re-parented, so no reload.
            rebuildTabBar()
        }
    }

    /// Builds a brand-new child `UITabBarController` and moves the cached content controllers into it. A fresh `UITabBar` is visible and reads the tinted appearance at creation; content state survives because the hosting controllers are reused. Used to restore the bar on immersion exit (a reused, re-shown bar comes back gray).
    func rebuildTabBar() {
        let selectedIndex = tabController.selectedIndex
        let viewControllers = tabController.viewControllers ?? []

        tabController.willMove(toParent: nil)
        tabController.view.removeFromSuperview()
        tabController.removeFromParent()

        let fresh = ShellChildTabBarController()
        fresh.delegate = self
        fresh.view.backgroundColor = .black
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

    /// Template symbol sized for the tvOS tab bar. `preferringMonochrome()` alone carries no point size, so symbols fall back to the ~17pt default (about half the bar's text height); compose an explicit size config (matching the prior SwiftUI TabView, measured at pointSize 29 / weight Medium / scale Medium) with the monochrome preference via `.applying()` (size and color are independent axes, so the merge keeps both). `.alwaysTemplate` keeps the iconColor tint over the `tv` symbol's baked hierarchical color.
    private static func tabIcon(_ name: String) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 29, weight: .medium, scale: .medium)
            .applying(UIImage.SymbolConfiguration.preferringMonochrome())
        return UIImage(systemName: name, withConfiguration: config)?.withRenderingMode(.alwaysTemplate)
    }
}

// MARK: - Immersion signal

enum ShellImmersionKey {
    /// Stable `UUID` identifying the posting view instance.
    static let token = "token"
    /// `Bool`: true on appear, false on disappear.
    static let active = "active"
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
    /// Stable for this view instance's lifetime, so a repeated onAppear (e.g. after a child sheet/cover dismisses) re-inserts the SAME token (a no-op) instead of drifting a counter.
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                NotificationCenter.default.post(
                    name: .shellTabBarImmersion, object: nil,
                    userInfo: [ShellImmersionKey.token: token, ShellImmersionKey.active: true]
                )
            }
            .onDisappear {
                NotificationCenter.default.post(
                    name: .shellTabBarImmersion, object: nil,
                    userInfo: [ShellImmersionKey.token: token, ShellImmersionKey.active: false]
                )
            }
    }
}
