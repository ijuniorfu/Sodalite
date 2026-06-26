import SwiftUI
import UIKit

/// Hides the app's single tab bar for full-screen detail immersion by setting the live `UITabBar`'s ALPHA to 0, never `isHidden` / `.toolbar(.hidden, for: .tabBar)`. On tvOS 26 the bar's SF Symbol icons are re-templated to system gray whenever the bar is removed from / re-added to the view hierarchy (which isHidden and `.toolbar(.hidden)` both do); alpha keeps the one bar instance attached, so the icon tint is never re-resolved. alpha <= 0.01 also drops the bar from the tvOS focus graph, so it is non-focusable while immersed. This is the SwiftUI form of the long-standing tvOS "never let the bar be hidden/removed" idiom.
@MainActor
final class TabBarImmersion {
    /// Stable per-view tokens; the bar is hidden iff non-empty. A Set (idempotent insert) survives SwiftUI re-firing onAppear (e.g. after a child sheet/cover dismisses) without drifting; a stray onDisappear for an unknown token is a no-op.
    private var tokens: Set<UUID> = []
    /// Debounce: only the latest event's deferred re-assert runs.
    private var generation = 0

    func handle(token: UUID, active: Bool) {
        if active { tokens.insert(token) } else { tokens.remove(token) }
        apply()
        // Re-assert once the nav push/pop transition settles, in case the transition animated the bar's alpha back.
        generation += 1
        let gen = generation
        deferOnMain(by: 0.45) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.apply()
        }
    }

    /// Re-assert the current alpha onto the live bar (e.g. after a background availableTabs change rebuilds the bar at alpha 1 while a detail is still open).
    func reassert() { apply() }

    private func apply() {
        let alpha: CGFloat = tokens.isEmpty ? 1 : 0
        var found = 0
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                found += Self.setTabBarAlpha(alpha, in: window)
            }
        }
        // DIAG (temporary): confirm the window-walk actually finds the live UITabBar and that our alpha is the value set. If barsFound is 0 the walk is wrong; if barsFound>=1 yet the bar still grays on return, the gray is tvOS's own bar management, not our hide.
        LogTap.shared.note("[Immersion] tokens=\(tokens.count) wantAlpha=\(alpha) barsFound=\(found)")
    }

    @discardableResult
    private static func setTabBarAlpha(_ alpha: CGFloat, in view: UIView) -> Int {
        var n = 0
        if let tabBar = view as? UITabBar {
            UIView.performWithoutAnimation { tabBar.alpha = alpha }
            n += 1
        }
        for subview in view.subviews { n += setTabBarAlpha(alpha, in: subview) }
        return n
    }
}

// MARK: - Immersion signal

enum ShellImmersionKey {
    /// Stable `UUID` of the posting view instance.
    static let token = "token"
    /// `Bool`: true on appear, false on disappear.
    static let active = "active"
}

extension View {
    /// Marks this view as a full-screen detail that hides the tab bar while on screen. Posts a per-view token on appear/disappear; TabRootView's `TabBarImmersion` alpha-hides the live bar. Deliberately does NOT use `.toolbar(.hidden, for: .tabBar)`, which removes/re-adds the bar and grays its icons on the way back on tvOS 26.
    func hidesShellTabBar() -> some View {
        modifier(ShellImmersionModifier())
    }
}

private struct ShellImmersionModifier: ViewModifier {
    /// Stable for this view instance's lifetime, so a repeated onAppear (after a child sheet/cover dismisses) re-inserts the SAME token (a no-op) instead of drifting a counter.
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
