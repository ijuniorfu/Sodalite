import SwiftUI

/// Raised by a screen that wants the shell's navigation out of the way while it is up. Both shells
/// read it, the sidebar (Sodalite#140) and the top bar, and neither lets the screen hide the
/// navigation itself. `||` rather than "last wins": with several screens on a stack, one of them
/// wanting the chrome gone is enough.
///
/// **A hide a screen applies to itself outlives the screen** (Sodalite#141). `toolbar(.hidden, for:
/// .tabBar)` sat on the pushed screen until the login probe published a narrower tab set, which
/// rebuilds the TabView's tab list and takes the Settings stack with it. The screen went, the hide
/// stayed, and the bar was left parked above the top edge: measured in the tvOS 27 simulator at
/// `frame={{0, -84.5}, {1920, 68}}` with every one of its five items unhittable, so focus could not
/// leave the page it was on. Opening any settings row and coming back cured it, because that pushes
/// and pops a screen that asserts the hide again.
///
/// A preference cannot strand anything: it is recomputed from the tree that exists, so a screen
/// that is gone stops asking, in the same update it disappears.
struct ShellChromeHiddenKey: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

#if os(tvOS)
/// Owns the tab bar's visibility for one tab of the top-bar shell, so no pushed screen has to.
///
/// It sits at the root of the tab's content, which means the tab-list rebuild that strands the bar
/// today REBUILDS this instead: a fresh host starts at "not hidden" and asserts the bar back, where
/// a modifier on the destroyed screen simply stopped existing and left the bar where it was
/// (Sodalite#141). One host per tab, so a detail left open in another tab cannot speak for the tab
/// on screen.
struct ShellChromeHost<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @State private var hidden = false

    var body: some View {
        content()
            .onPreferenceChange(ShellChromeHiddenKey.self) { value in
                hidden = value
            }
            // .visible rather than .automatic: automatic is what a stranded hide survives in.
            .toolbar(hidden ? .hidden : .visible, for: .tabBar)
    }
}
#endif

extension View {
    /// Asks the shell to take its navigation away while this full-screen detail is on screen
    /// (pushed details that are NOT presented as a cover still need this). Details presented via a
    /// full-screen cover do not need it: the cover covers the bar without ever removing it, so the
    /// bar is never re-templated gray on dismiss.
    ///
    /// It only asks. `TabRootView` is what hides the bar, so the hide cannot survive the screen
    /// that wanted it (Sodalite#141).
    func hidesShellTabBar() -> some View {
        // tvOS-only: hiding the tab bar stops tvOS re-templating its icons gray on a pushed
        // detail. On iOS the hide is what strands the bar after a pop, so keep the native
        // tab bar (it hides/restores correctly on push/pop by itself).
        #if os(tvOS)
        return preference(key: ShellChromeHiddenKey.self, value: true)
        #else
        return self
        #endif
    }
}
