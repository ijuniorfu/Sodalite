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

    /// How much room the rail takes in the LAYOUT. Set without animation, because a
    /// `NavigationStack` is UIKit-backed on tvOS and does not interpolate a width handed to it from
    /// outside: measured in the simulator, the cards stand still through the whole animation and
    /// snap at the end. The movement is done by `shift` instead.
    @State private var railSlot: CGFloat = SidebarMetrics.railSlot
    /// The visual correction that makes the layout jump invisible: set to the difference in the
    /// same frame the layout changes, then animated back to zero. A transform, unlike a width, is a
    /// layer property that UIKit does interpolate, so the content travels with the rail.
    @State private var shift: CGFloat = 0

    /// First the layout, then the correction, then play it out: the layout lands on its new width
    /// in one unanimated step, `shift` cancels that step visually, and animating `shift` back to
    /// zero is what the viewer actually sees. Doing it the obvious way instead (animate the width)
    /// leaves the content standing still until the animation ends, see `railSlot`.
    private func setChrome(hidden: Bool) {
        let target: CGFloat = hidden ? 0 : SidebarMetrics.railSlot
        guard target != railSlot else { return }
        let delta = railSlot - target

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            railSlot = target
            shift = delta
            chromeHidden = hidden
        }

        withAnimation(.easeInOut(duration: SidebarMetrics.expandDuration)) {
            shift = 0
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Layout placeholder only. The rail itself is an overlay, so it can move freely while
            // this width changes in one step underneath it.
            Color.clear
                .frame(width: railSlot)

            content(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.shellPaysLeadingInset, !chromeHidden)
                .offset(x: shift)
                .focusSectionCompat()
                // The shell opens on the content, not on the rail, which is what the top bar does.
                .prefersDefaultFocus(true, in: shellFocus)
                .onPreferenceChange(ShellChromeHiddenKey.self) { hidden in
                    setChrome(hidden: hidden)
                }
        }
        .overlay(alignment: .leading) {
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
            .padding(.leading, SidebarMetrics.railLeadingInset)
            // Rides the same correction as the content, so the two move as one, and steps aside
            // entirely once the layout has closed the gap.
            .offset(x: shift - (chromeHidden ? SidebarMetrics.railSlot : 0))
            .opacity(chromeHidden ? 0 : 1)
            .disabled(chromeHidden)
        }
        // ONE opt-out, for the whole shell. On a child alone it does not work: the HStack still
        // starts inside the 60pt title-safe margin, so the rail reaches the edge while the content
        // begins 60pt further right, and the two gaps around the rail can never match. Measured in
        // the simulator: 38pt on the left against 120 on the right.
        .ignoresSafeArea(edges: .leading)
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
