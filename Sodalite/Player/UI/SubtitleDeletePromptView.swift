import SwiftUI

/// Feature #4: confirm / progress / error prompt for deleting an external
/// subtitle (hold Select on an external row in the subtitle dropdown).
/// DISPLAY-ONLY: it renders from `viewModel.subtitleDeleteState` /
/// `subtitleDeleteFocus`; PlayerHostController routes all remote input,
/// because the player host has user interaction disabled like every other
/// player overlay.
struct SubtitleDeletePromptView: View {
    @Bindable var viewModel: PlayerViewModel
    var tint: Color

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 28) {
                content
            }
            .padding(48)
            .frame(width: 760)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.subtitleDeleteState {
        case .hidden:
            EmptyView()
        case .confirm:
            Text("player.subtitle.delete.title")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                button(
                    title: String(localized: "common.cancel", defaultValue: "Cancel"),
                    focused: viewModel.subtitleDeleteFocus == .cancel,
                    destructive: false
                )
                button(
                    title: String(localized: "player.subtitle.delete.confirm", defaultValue: "Delete"),
                    focused: viewModel.subtitleDeleteFocus == .delete,
                    destructive: true
                )
            }
        case .deleting:
            ProgressView()
            Text("player.subtitle.delete.deleting")
                .foregroundStyle(.secondary)
        case .error(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func button(title: String, focused: Bool, destructive: Bool) -> some View {
        Text(title)
            .fontWeight(.semibold)
            .padding(.horizontal, 36)
            .padding(.vertical, 14)
            .foregroundStyle(focused ? .black : (destructive ? .red : .primary))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(focused ? (destructive ? Color.red : tint) : Color.white.opacity(0.12))
            )
    }
}
