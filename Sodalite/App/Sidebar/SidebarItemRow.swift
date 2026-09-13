#if os(tvOS)
import SwiftUI

/// Where focus can sit inside the shell. The content's own focus stays the content's business.
enum SidebarFocus: Hashable {
    case item(AppTab)
}

/// Sodalite#140. One rail row. Deliberately thin: every decision it could get wrong lives in
/// `SidebarItemState` and `SidebarMetrics`, which are pinned by tests.
struct SidebarItemRow: View {
    let tab: AppTab
    let isSelected: Bool
    let isExpanded: Bool
    @FocusState.Binding var focus: SidebarFocus?
    let onSelect: () -> Void

    @Environment(\.appearanceTheme) private var appearanceTheme

    private var isFocused: Bool { focus == .item(tab) }

    private var state: SidebarItemState {
        .resolve(isFocused: isFocused, isSelected: isSelected)
    }

    private var iconColor: Color {
        state.usesAccentIcon ? appearanceTheme.palette.control.color : state.iconFallbackColor
    }

    var body: some View {
        HStack(spacing: 16) {
            // .monochrome for the same reason the tab bar needs it: "tv" renders hierarchically and
            // would otherwise ignore the colour it is given.
            Image(systemName: tab.systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: SidebarMetrics.iconSize))
                .foregroundStyle(iconColor)
                .frame(width: SidebarMetrics.iconColumn)
            if isExpanded {
                Text(tab.labelKey)
                    .font(.title3)
                    .foregroundStyle(state.labelColor)
                    .lineLimit(1)
                    // NOT fixedSize: that makes a long label (German "Einstellungen") wider than
                    // the rail and it then draws straight over the content beside it.
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, SidebarMetrics.itemHorizontalPadding(isExpanded: isExpanded))
        .padding(.vertical, SidebarMetrics.itemVerticalPadding)
        .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
        .background(
            RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius)
                .fill(state.fill)
        )
        .focusable(true)
        .focused($focus, equals: .item(tab))
        // The house helper for a Select press on a focusable row, focus-gated like every other one.
        .stableTap(isFocused: isFocused) {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}
#endif
