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
    @State private var focusIsInRail = true

    var body: some View {
        HStack(spacing: SidebarMetrics.horizontalPadding) {
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
            .padding(.leading, SidebarMetrics.horizontalPadding)

            content(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSectionCompat()
        }
        .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: focusIsInRail)
        .onChange(of: focus) { _, newValue in
            focusIsInRail = newValue != nil
        }
        .onExitCommandCompat {
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
        .defaultFocus($focus, .item(selectedTab))
    }
}
#endif
