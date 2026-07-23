import SwiftUI

/// Focusable card avoiding tvOS's default white focus border; use instead of Button for media cards and settings tiles.
struct FocusableCard<Content: View>: View {
    let action: () -> Void
    var highlightsOnPress = false
    var exposesButtonSemantics = false
    @ViewBuilder let content: (_ isFocused: Bool) -> Content

    @FocusState private var isFocused: Bool
    @GestureState private var isPressed = false

    @ViewBuilder
    var body: some View {
        if exposesButtonSemantics {
            pressAwareCard
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            pressAwareCard
        }
    }

    private var baseCard: some View {
        content(isHighlighted)
            .focusable()
            .focused($isFocused)
            .stableTap(isFocused: isFocused) { action() }
            .scaleEffect(isHighlighted ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isHighlighted ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }

    @ViewBuilder
    private var pressAwareCard: some View {
        #if os(iOS)
        if highlightsOnPress {
            baseCard.simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { value, pressed, _ in
                        pressed = abs(value.translation.width) <= 24
                            && abs(value.translation.height) <= 24
                    }
            )
        } else {
            baseCard
        }
        #else
        baseCard
        #endif
    }

    private var isHighlighted: Bool {
        #if os(iOS)
        isFocused || (highlightsOnPress && isPressed)
        #else
        isFocused
        #endif
    }
}
