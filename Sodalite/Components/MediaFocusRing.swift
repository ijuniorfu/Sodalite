import SwiftUI

struct MediaFocusRing<Shape: InsettableShape>: View {
    let shape: Shape
    let isFocused: Bool

    @Environment(\.appearanceTheme) private var appearanceTheme

    var body: some View {
        shape
            .strokeBorder(
                appearanceTheme.palette.focus.color,
                lineWidth: 4
            )
            .padding(-4)
            .shadow(
                color: appearanceTheme.palette.focus.color.opacity(isFocused ? 0.32 : 0),
                radius: 9
            )
            .opacity(isFocused ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            .accessibilityHidden(true)
    }
}
