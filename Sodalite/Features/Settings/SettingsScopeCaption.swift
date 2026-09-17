import SwiftUI

/// Who a settings row belongs to. Most values follow the profile on screen; `.device` marks a value
/// every profile on this box shares (buffers, audio bridge, display, remote and Top Shelf values).
enum SettingsValueScope: Sendable {
    case profile
    case device
}

private struct SettingsValueScopeKey: EnvironmentKey {
    static let defaultValue = SettingsValueScope.profile
}

extension EnvironmentValues {
    var settingsValueScope: SettingsValueScope {
        get { self[SettingsValueScopeKey.self] }
        set { self[SettingsValueScopeKey.self] = newValue }
    }
}

extension View {
    /// Marks the settings row it is applied to. `ValuePickerRow` draws the mark inside its own card,
    /// so it can never read as belonging to the row below.
    func settingsValueScope(_ scope: SettingsValueScope) -> some View {
        environment(\.settingsValueScope, scope)
    }
}

/// The line under a settings title naming the profile the screen's values belong to.
struct SettingsScopeCaption: View {
    @Environment(\.appState) private var appState

    var body: some View {
        Label {
            Text(String(
                format: String(localized: "settings.scope.profile", defaultValue: "Applies to the profile %@"),
                appState.activeUser?.name ?? ""
            ))
        } icon: {
            Image(systemName: "person.crop.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The device mark a `ValuePickerRow` carries when its value is shared by every profile on the box.
struct DeviceScopeMark: View {
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var text: String {
        String(localized: "settings.scope.device", defaultValue: "Applies to this device")
    }

    private var symbol: String {
        #if os(tvOS)
        "tv"
        #else
        "iphone"
        #endif
    }
}
