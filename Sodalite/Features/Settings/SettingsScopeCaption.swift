import SwiftUI

/// One line that says who a setting belongs to: under a settings title, the profile on screen (most
/// values follow the profile), and under a device row, this device (buffers, audio bridge, display,
/// remote and Top Shelf values, which every profile on the box shares).
struct SettingsScopeCaption: View {
    enum Scope { case profile, device }

    @Environment(\.appState) private var appState
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private let scope: Scope

    init(_ scope: Scope) {
        self.scope = scope
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // A device caption belongs to the row above it: it starts where that row's content does, and
        // keeps more room below than the stack spacing above, or it reads as the next row's caption.
        .padding(.leading, scope == .device ? (hSizeClass == .compact ? 16 : 28) : 0)
        .padding(.bottom, scope == .device ? 12 : 0)
    }

    private var text: String {
        switch scope {
        case .profile:
            String(
                format: String(localized: "settings.scope.profile", defaultValue: "Applies to the profile %@"),
                appState.activeUser?.name ?? ""
            )
        case .device:
            String(localized: "settings.scope.device", defaultValue: "Applies to this device")
        }
    }

    private var symbol: String {
        switch scope {
        case .profile:
            "person.crop.circle"
        case .device:
            #if os(tvOS)
            "tv"
            #else
            "iphone"
            #endif
        }
    }
}
