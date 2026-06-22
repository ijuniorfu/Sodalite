import SwiftUI

// MARK: - Value Picker Row

/// Full-width settings row: left/right cycles options directly (no dropdown), Select also advances forward, chevrons are cues not focus targets.
struct ValuePickerRow<Value: Hashable>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 36) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .frame(width: 64)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.body)
                    .foregroundStyle(focused ? .white : Color.secondary)
                    .opacity(canMoveBackward ? 1 : 0.25)
                Text(label(selection))
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(focused ? .white : Color.white.opacity(0.85))
                    .frame(minWidth: 110, alignment: .center)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.right")
                    .font(.body)
                    .foregroundStyle(focused ? .white : Color.secondary)
                    .opacity(canMoveForward ? 1 : 0.25)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 6)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: selection)
        .onMoveCommand { direction in
            switch direction {
            case .left:  advance(by: -1)
            case .right: advance(by: 1)
            default: break
            }
        }
        // Click also advances forward for users who prefer clicking over swiping.
        .stableTap(isFocused: focused) {
            advance(by: 1)
        }
    }

    private var currentIndex: Int {
        options.firstIndex(of: selection) ?? 0
    }

    private var canMoveBackward: Bool { currentIndex > 0 }
    private var canMoveForward: Bool { currentIndex < options.count - 1 }

    /// Clamps at the ends, no wrap (disorienting for short lists like "Off / 5s / 10s / 15s").
    private func advance(by step: Int) {
        let newIdx = max(0, min(options.count - 1, currentIndex + step))
        if newIdx != currentIndex {
            selection = options[newIdx]
        }
    }
}
