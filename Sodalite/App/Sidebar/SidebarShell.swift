#if os(tvOS)
import SwiftUI

/// Sodalite#140. The tvOS navigation shell when the viewer picked the sidebar: rail on the left,
/// the selected tab's content beside it. The rail PUSHES rather than covers, which is what lets it
/// carry the accent and what separates it from the system sidebar.
///
/// Walking the rail moves focus only. The content changes on Select, so running through seven tabs
/// costs no loads, and Live TV in particular is not woken up in passing.
struct SidebarShell<Content: View>: View {
    let tabs: [AppTab]
    @Binding var selectedTab: AppTab
    @ViewBuilder let content: (AppTab) -> Content

    @FocusState private var focus: SidebarFocus?
    /// Mirrors the focus so the animation has something to compare, and so the Menu policy can ask
    /// where focus is without reading `@FocusState` mid-update.
    /// Starts false: the app opens on the content, the way it does with the top bar.
    @State private var focusIsInRail = false
    @Namespace private var shellFocus
    /// Raised by a pushed screen that wants the navigation out of the way (Settings sub-screens,
    /// the licence reader, Home's customiser). The rail then has to go, but NOT by taking a
    /// different branch: that rebuilds the content and the pushed screen's own stack goes with it.
    @State private var chromeHidden = false

    var body: some View {
        // A small gap, not the screens' own margin: most bring an 80pt screenHInset of their own,
        // but the Live TV guide draws flush and would otherwise touch the rail.
        HStack(spacing: chromeHidden ? 0 : SidebarMetrics.contentGap) {
            SidebarRail(
                tabs: tabs,
                selectedTab: selectedTab,
                isExpanded: focusIsInRail,
                focus: $focus,
                onSelect: { tab in
                    // Select commits the tab and hands focus back to the content, so the rail
                    // collapses in the same gesture.
                    selectedTab = tab
                    focus = nil
                }
            )
            .padding(.leading, chromeHidden ? 0 : SidebarMetrics.railLeadingInset)
            // The inset above is measured from the physical edge, so the rail has to opt out of the
            // safe area it would otherwise be pushed inside of.
            .ignoresSafeArea(edges: .leading)
            .frame(width: chromeHidden ? 0 : nil)
            .opacity(chromeHidden ? 0 : 1)
            .disabled(chromeHidden)

            content(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.shellPaysLeadingInset, !chromeHidden)
                .focusSectionCompat()
                // The shell opens on the content, not on the rail, which is what the top bar does.
                .prefersDefaultFocus(true, in: shellFocus)
                .onPreferenceChange(ShellChromeHiddenKey.self) { hidden in
                    chromeHidden = hidden
                }
        }
        .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: focusIsInRail)
        .onChange(of: focus) { _, newValue in
            focusIsInRail = newValue != nil
        }
        // Menu is ours only while the rail is on screen. On a pushed screen the navigation stack
        // owns it, and an installed handler would swallow the press that should pop the screen,
        // hence the nil rather than an empty closure.
        .onExitCommandIfEnabled(!chromeHidden) {
            switch SidebarExitPolicy.next(focusIsInRail: focusIsInRail, selectedTab: selectedTab) {
            case .focusRail:
                focus = .item(selectedTab)
            case .selectHome:
                selectedTab = .home
                focus = .item(.home)
            case .leaveApp:
                // Nothing: letting the press fall through is what leaves the app.
                break
            }
        }
        .focusScope(shellFocus)
    }
}
#endif
