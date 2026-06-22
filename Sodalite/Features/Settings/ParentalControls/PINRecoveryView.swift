import SwiftUI

/// PIN recovery: prove control of an unprotected account via its Jellyfin password; recovery bound to existing server creds.
struct PINRecoveryView: View {
    @Environment(\.dependencies) private var dependencies

    let onRecovered: () -> Void
    let onCancel: () -> Void

    @State private var candidates: [(server: JellyfinServer, user: RememberedUser)] = []
    @State private var selected: RememberedUser?
    @State private var selectedServer: JellyfinServer?
    @State private var password = ""
    @State private var error: LocalizedStringKey?
    @State private var isValidating = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 32) {
                Text("parental.pin.recovery.title")
                    .font(.title2).fontWeight(.semibold)
                Text("parental.pin.recovery.subtitle")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 700)

                if selected == nil {
                    profileList
                } else {
                    passwordEntry
                }

                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }

                Button(role: .cancel, action: onCancel) {
                    Label("common.cancel", systemImage: "xmark")
                        .padding(.horizontal, 24).padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
            .padding(60)
        }
        .onAppear(perform: loadCandidates)
    }

    private var profileList: some View {
        VStack(spacing: 8) {
            ForEach(candidates, id: \.user.id) { entry in
                Button {
                    selected = entry.user
                    selectedServer = entry.server
                    error = nil
                } label: {
                    HStack {
                        Text(entry.user.name).font(.body).fontWeight(.medium)
                        Spacer()
                        Text(entry.server.name).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
        }
        .frame(maxWidth: 700)
        .focusSection()
    }

    private var passwordEntry: some View {
        VStack(spacing: 20) {
            Text(selected?.name ?? "").font(.headline)
            SecureField("auth.password.placeholder", text: $password)
                .textContentType(.password)
                .frame(maxWidth: 500)
            Button {
                Task { await validate() }
            } label: {
                Label("parental.pin.recovery.verify", systemImage: "checkmark.shield")
                    .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
            .disabled(password.isEmpty || isValidating)
        }
        .focusSection()
    }

    private func loadCandidates() {
        var result: [(JellyfinServer, RememberedUser)] = []
        for server in dependencies.listKnownServers() {
            for user in dependencies.listRememberedUsers(serverID: server.id)
            where !dependencies.parentalControlsPreferences.isProtected(serverID: server.id, userID: user.id) {
                result.append((server, user))
            }
        }
        candidates = result.map { (server: $0.0, user: $0.1) }
    }

    private func validate() async {
        guard let user = selected, let server = selectedServer else { return }
        isValidating = true
        defer { isValidating = false }
        // login() is a pure REST call; does not mutate stored session/token. Restore previous baseURL on failure (tidiness, not a leak; active token unchanged).
        let previousBaseURL = dependencies.jellyfinClient.baseURL
        dependencies.jellyfinClient.baseURL = server.url
        do {
            _ = try await dependencies.jellyfinAuthService.login(
                username: user.name, password: password
            )
            onRecovered()
        } catch {
            dependencies.jellyfinClient.baseURL = previousBaseURL
            self.error = "parental.pin.recovery.failed"
        }
    }
}
