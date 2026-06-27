import SwiftUI

extension View {
    /// Presents a full-screen detail as a cover (over the tab bar) instead of a NavigationStack push. The cover covers the tab bar WITHOUT ever removing it, so tvOS never re-templates the bar's icons gray on return (the tvOS 26 system bug that a `.toolbar(.hidden)` push triggers). Each cover hosts its own NavigationStack so the detail's deeper navigation (detail -> detail, -> person) still pushes normally.
    ///
    /// A `glassBackground()` sits behind the stack as a uniform backing: detail views draw their own full-screen backdrop over it, while backdrop-less pages (filter grids, person/album pages that used to inherit the root `Color.black`) show the glass instead of being see-through over the presenter.
    func detailCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        fullScreenCover(item: item) { value in
            NavigationStack {
                content(value)
            }
            .glassBackground()
            #if os(iOS)
            // tvOS dismisses via the Menu button; iOS needs a touch close (a fullScreenCover
            // has no swipe-to-dismiss), else detail / program-info covers are a dead end.
            // Top-trailing glass circle (matching the settings gear) so it never sits on the
            // leading page title.
            .overlay(alignment: .topTrailing) {
                Button { item.wrappedValue = nil } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .padding(12)
                        .glassEffect(.regular, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.top, 8)
            }
            #endif
        }
    }
}
