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

/// `UITabBarController` that appends the tab bar as a focus fallback so it is reachable while Home's content is still loading on cold launch (the engine otherwise drives focus into the empty Home host and never settles, leaving the bar unreachable until the first row appears - something SwiftUI's TabView handled for free). Once content is loaded the engine picks it first, so the fallback is only consulted when the selected content has no focusable item; during immersion the bar is alpha 0, so it is skipped then too.
final class ShellChildTabBarController: UITabBarController {
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        super.preferredFocusEnvironments + [tabBar]
    }
}

/// Container hosting a child `UITabBarController`. Immersion hides the bar via alpha (never isHidden), so the bar is never re-templated and stays tinted; the cached content controllers are never disturbed, so a detail back-out restores focus natively.
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
        // Transparent shell: a page's .regularMaterial glass background must capture the real app backdrop behind the shell to read as glass; a flat black fill here flattened it to dead black. Clear also means a tab switch reveals that (dark) backdrop, not a white default, so it does not reintroduce the white flash.
        view.backgroundColor = .clear
        tabController.delegate = self
        addChild(tabController)
        tabController.view.frame = view.bounds
        tabController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tabController.view.backgroundColor = .clear
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
        if active {
            immersionTokens.insert(token)   // idempotent: a repeated onAppear is a no-op, so the set cannot drift
        } else {
            immersionTokens.remove(token)   // no-op for an unknown token, so a stray onDisappear cannot underflow
        }
        let isImmersed = !immersionTokens.isEmpty
        // No edge guard: set alpha from the CURRENT set state on every event, so a missed empty<->non-empty edge (out-of-order onAppear/onDisappear in deep nested navigation) cannot leave the bar stuck invisible.
        // Hide via alpha, NOT isHidden, and never rebuild: isHidden re-templates the reused bar gray on re-show and forced a fresh-controller rebuild whose re-parenting wiped the tvOS focus memory, so a detail back-out jumped focus up to the bar. alpha 0 hides the bar AND drops it from the focus graph (tvOS skips alpha <= 0.01) without ever re-templating it, so it stays tinted, no rebuild is needed, and the back-out restores focus to the row natively. The bar keeps its layout slot (a safe-area inset), but details use .ignoresSafeArea so they still fill full-screen under the now-invisible bar.
        tabController.tabBar.alpha = isImmersed ? 0 : 1
        // DIAG (temporary): trace the token balance + resulting alpha to find why the catalog bar gets stuck invisible after nested navigation.
        LogTap.shared.note("[Immersion] \(active ? "+" : "-")\(token.uuidString.prefix(4)) count=\(immersionTokens.count) alpha=\(isImmersed ? 0 : 1)")
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
