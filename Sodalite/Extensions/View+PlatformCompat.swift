import SwiftUI

struct ThemeNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content().themedNavigationDestination()
        }
    }
}

struct ThemeNavigationPathStack<Content: View>: View {
    @Binding var path: NavigationPath
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack(path: $path) {
            content().themedNavigationDestination()
        }
    }
}

extension View {
    @ViewBuilder
    func themedNavigationDestination() -> some View {
        #if os(iOS)
        containerBackground(.clear, for: .navigation)
        #else
        self
        #endif
    }
}

// No-op-on-iOS shims for tvOS-only focus/command modifiers so shared views
// compile Universal. On tvOS the real modifier applies; on iOS the equivalent
// affordance comes from native touch navigation (back swipe / Now Playing remote)
// or is wired up in a later port phase. Keep call sites identical across platforms.
//
// onMoveCommand is also tvOS-only but carries real navigation behavior with no
// iOS analog yet, so it is gated inline with #if os(tvOS) at each site (replaced
// by touch controls in Phase 2) rather than silently no-op'd here.
extension View {
    @ViewBuilder
    func focusSectionCompat() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder
    func focusScopeCompat(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        focusScope(namespace)
        #else
        self
        #endif
    }

    @ViewBuilder
    func prefersDefaultFocusCompat(_ prefersDefaultFocus: Bool, in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        self.prefersDefaultFocus(prefersDefaultFocus, in: namespace)
        #else
        self
        #endif
    }

    /// Hands focus back to a caller-chosen control when the viewer moves up out of this view.
    ///
    /// The focus engine resolves an up-move geometrically, from the centre of the view holding
    /// focus, and consults nothing else: a full-width element under a short left-aligned button
    /// row therefore lands on the row's LAST button, which on a detail page is Delete (Sodalite#53).
    /// Measured in a tvOS focus probe; .focusSection, a section on both sides of the boundary, and
    /// focusScope + prefersDefaultFocus all leave the landing unchanged, so the correction has to be
    /// explicit. The engine still moves first and this runs ~30ms behind it, which is why `action`
    /// must only hand focus somewhere, never act on it.
    ///
    /// Passing nil keeps stock navigation, so shared components stay unchanged for callers with no
    /// primary control to return to.
    @ViewBuilder
    func onFocusMoveUp(_ action: (() -> Void)?) -> some View {
        #if os(tvOS)
        if let action {
            onMoveCommand { direction in
                if direction == .up { action() }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Same correction for one row of a ForEach: the modifier is applied unconditionally and the
    /// flag is checked inside, so row one keeps the exact view shape of its siblings. Branching the
    /// modifier itself hands the focus engine two different shapes in one list, which is what the
    /// value-based focus binding in CollectionDetailView already works around.
    @ViewBuilder
    func onFocusMoveUp(active: Bool, _ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onMoveCommand { direction in
            if direction == .up, active { action() }
        }
        #else
        self
        #endif
    }

    /// Applies .ignoresSafeArea only when `active`. Lets a detail screen stay full-bleed on
    /// tvOS/iPad while its scroll content respects the safe area on iPhone portrait (so the
    /// content is not clipped under the status bar / home indicator).
    @ViewBuilder
    func ignoresSafeArea(when active: Bool, edges: Edge.Set = .all) -> some View {
        if active {
            ignoresSafeArea(edges: edges)
        } else {
            self
        }
    }

    /// tvOS hides the navigation bar (it uses the Menu button to go back); iOS keeps the
    /// native bar so pushed screens get a back button and the interactive swipe-back gesture.
    @ViewBuilder
    func hidesNavigationBarChrome() -> some View {
        #if os(tvOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func onExitCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }

    @ViewBuilder
    func onPlayPauseCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onPlayPauseCommand(perform: action)
        #else
        self
        #endif
    }

    /// Outer screen padding scaled by size class (tvOS 80/60, iPad 40/32, iPhone 16/16).
    /// Replaces the hardcoded tvOS 10-foot `.padding(.vertical, 60).padding(.horizontal, 80)`
    /// that starved content width on compact iPhone. tvOS resolves to the tv tier unchanged.
    func screenContentInset() -> some View { modifier(ScreenContentInset()) }
}

private struct ScreenContentInset: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    func body(content: Content) -> some View {
        let m = LayoutMetrics.current(hSizeClass)
        return content
            .padding(.horizontal, m.screenHInset)
            .padding(.vertical, m.screenVInset)
    }
}
