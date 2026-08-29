import SwiftUI
import UIKit

/// What the app says when this device is withholding Local Network access (Sodalite#92).
///
/// It covers everything, because with the permission off everything behind it is dead: every
/// library row, every image, every stream lives at a LAN address the app is not allowed to open.
/// The generic "check the connection" line it replaces is not merely vague, it is a wrong lead, and
/// it costs reporters a router restart and a support ticket before anybody thinks of Settings.
///
/// The Settings jump is offered only where the device will actually perform it, asked at runtime
/// rather than assumed per platform. The written path is always shown, so a device that cannot jump
/// still tells the viewer where to go.
struct LocalNetworkDeniedView: View {
    /// Re-probes and dismisses if the permission is back. Owned by AppRouter, which also holds the
    /// reload that follows.
    let onRetry: () async -> Void

    @State private var isRetrying = false

    private var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    private var canOpenSettings: Bool {
        guard let settingsURL else { return false }
        return UIApplication.shared.canOpenURL(settingsURL)
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "network.slash")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                VStack(spacing: 12) {
                    Text("localNetwork.denied.title")
                        .font(.title2)
                        .multilineTextAlignment(.center)

                    Text("localNetwork.denied.body")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(settingsPath)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 700)
            }

            VStack(spacing: 16) {
                if canOpenSettings, let settingsURL {
                    Button {
                        UIApplication.shared.open(settingsURL)
                    } label: {
                        Text("localNetwork.denied.openSettings")
                            .font(.body)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(SettingsTileButtonStyle(isProminent: true))
                }

                Button {
                    Task {
                        isRetrying = true
                        await onRetry()
                        isRetrying = false
                    }
                } label: {
                    if isRetrying {
                        ProgressView()
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    } else {
                        Text("home.retry")
                            .font(.body)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                }
                .buttonStyle(SettingsTileButtonStyle())
                .disabled(isRetrying)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedRootBackground()
    }

    /// Where the toggle lives, in the device's own words. tvOS files privacy under General, which is
    /// the wording Apple itself uses on that platform.
    private var settingsPath: LocalizedStringKey {
        #if os(tvOS)
        "localNetwork.denied.path.tv"
        #else
        "localNetwork.denied.path"
        #endif
    }
}
