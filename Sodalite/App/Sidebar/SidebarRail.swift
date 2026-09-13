#if os(tvOS)
import SwiftUI

/// Sodalite#140. The rail. Vertically centred as one block rather than starting at the top, which
/// reads cleaner on a TV and keeps the icons near the eye line whatever the tab count.
///
/// Settings sits below a divider because it is not a browsing destination. In the collapsed rail
/// that divider shrinks to the icon column, otherwise it draws a line across empty space.
struct SidebarRail: View {
    let tabs: [AppTab]
    let selectedTab: AppTab
    let isExpanded: Bool
    @FocusState.Binding var focus: SidebarFocus?
    let onSelect: (AppTab) -> Void

    /// Settings is pulled out of the flow above and placed under the divider.
    private var browsingTabs: [AppTab] { tabs.filter { $0 != .settings } }
    private var hasSettings: Bool { tabs.contains(.settings) }

    private var dividerWidth: CGFloat {
        isExpanded ? SidebarMetrics.expandedWidth - SidebarMetrics.horizontalPadding * 2
                   : SidebarMetrics.iconColumn
    }

    var body: some View {
        VStack(alignment: isExpanded ? .leading : .center, spacing: SidebarMetrics.itemSpacing) {
            ActiveUserBadge()
                .padding(.vertical, SidebarMetrics.itemVerticalPadding)

            ForEach(browsingTabs, id: \.self) { tab in
                SidebarItemRow(
                    tab: tab,
                    isSelected: tab == selectedTab,
                    isExpanded: isExpanded,
                    focus: $focus,
                    onSelect: { onSelect(tab) }
                )
            }

            if hasSettings {
                Rectangle()
                    .fill(Color.Theme.hairline)
                    .frame(width: dividerWidth, height: SidebarMetrics.dividerHeight)

                SidebarItemRow(
                    tab: .settings,
                    isSelected: selectedTab == .settings,
                    isExpanded: isExpanded,
                    focus: $focus,
                    onSelect: { onSelect(.settings) }
                )
            }
        }
        .frame(width: SidebarMetrics.width(isExpanded: isExpanded))
        .frame(maxHeight: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: SidebarMetrics.panelCornerRadius)
                .fill(Color.Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: SidebarMetrics.panelCornerRadius)
                        .strokeBorder(Color.Theme.panelEdge, lineWidth: 1)
                )
                .opacity(isExpanded ? 1 : 0)
        )
        .focusSectionCompat()
    }
}
#endif
