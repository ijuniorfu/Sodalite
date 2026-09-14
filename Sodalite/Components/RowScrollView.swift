import SwiftUI

/// The horizontal scroller under a browse row, and the one place a row's leading margin is split
/// between the scroll view's own frame and the content inside it.
///
/// A `ScrollView` clips to its own bounds. A row that pays its whole margin as padding INSIDE the
/// scroll view therefore clips at the content area's leading edge, and beside the sidebar that edge
/// is the rail: the first card keeps its margin while it rests, and the moment the row scrolls the
/// cards run into the rail with no gap left at all (reported on Home, Live TV and Catalog alike).
/// Paying part of the margin on the scroll view moves the clip line clear of the rail; what stays
/// inside is what the first card needs to grow into when it takes focus.
///
/// Split only beside the sidebar. Without it the clip line is the screen's own safe-area edge, with
/// nothing standing next to it, which is where a tvOS row is supposed to end.
struct RowScrollView<Content: View>: View {
    /// The row's whole leading margin, the same number its heading is padded by.
    let leading: CGFloat
    let trailing: CGFloat
    var vertical: CGFloat = 0
    @ViewBuilder let content: () -> Content

    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading

    /// One clip line for every row whatever margin the row itself carries, so cards on two stacked
    /// rows leave the screen at the same place. Never far enough in to eat the overhang.
    private var clip: CGFloat {
        guard shellPaysLeading else { return 0 }
        return max(0, min(SidebarMetrics.rowClipLeading, leading - SidebarMetrics.rowFocusOverhang))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .padding(.leading, leading - clip)
                .padding(.trailing, trailing)
                .padding(.vertical, vertical)
        }
        .padding(.leading, clip)
    }
}
