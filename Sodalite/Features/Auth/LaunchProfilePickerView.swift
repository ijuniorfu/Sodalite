import SwiftUI

/// Shown on cold launch when the user has multiple remembered
/// profiles for the active server. Picking a card re-uses the
/// cached token via `switchToUser`, no password re-entry.
///
/// Long-pressing a card opens a confirm-to-forget menu. The
/// "Add another profile" button jumps straight to LoginView for
/// the same server (server discovery is already done).
struct LaunchProfilePickerView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies

    let server: JellyfinServer

    @State private var rememberedUsers: [RememberedUser] = []
    @State private var navigateToAddProfile = false
    @State private var switchError: String?
    @State private var showServerSwitchSheet = false
    @State private var showAddServerFlow = false

    /// Anchors the focus scope so cold-launch focus lands on a profile card, not the server-switch button (issue #25).
    @Namespace private var focusNamespace

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                header

                profileGrid

                serverSwitchButton

                addProfileButton
                    .focusSection()
            }
            .focusScope(focusNamespace)
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassBackground()
            .navigationDestination(isPresented: $navigateToAddProfile) {
                UserPickerView(server: server)
            }
            .alert(
                String(localized: "profile.switch.failed.title",
                       defaultValue: "Couldn't switch profile"),
                isPresented: Binding(
                    get: { switchError != nil },
                    set: { if !$0 { switchError = nil } }
                ),
                presenting: switchError
            ) { _ in
                Button(String(localized: "common.ok", defaultValue: "OK")) {
                    switchError = nil
                }
            } message: { message in
                Text(message)
            }
            .onAppear {
                rememberedUsers = dependencies.listRememberedUsers(serverID: server.id)
            }
            .sheet(isPresented: $showServerSwitchSheet) {
                ServerSwitchSheet(
                    onAddServer: {
                        showAddServerFlow = true
                    },
                    onSwitched: { _ in
                        // Picker re-resolves the active server from environment dependencies on next render.
                    }
                )
            }
            .fullScreenCover(isPresented: $showAddServerFlow) {
                ServerDiscoveryView(addMode: true) {
                    showAddServerFlow = false
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Text(server.name)
                .font(.title2)
                .fontWeight(.semibold)

            Text(String(
                localized: "profile.launch.subtitle",
                defaultValue: "Who's watching?"
            ))
            .font(.body)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Server switch

    private var serverSwitchButton: some View {
        Button(action: { gateThenServerSwitch() }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("multiServer.picker.header.label", bundle: .main)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(server.name)
                        .font(.headline)
                    Text(server.url.host() ?? server.url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .buttonStyle(.card)
        .frame(maxWidth: 560)
    }

    // MARK: - Grid

    private var profileGrid: some View {
        let columnCount = max(1, min(rememberedUsers.count, 5))
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(200), spacing: 32),
                    count: columnCount
                ),
                spacing: 40
            ) {
                ForEach(rememberedUsers) { user in
                    RememberedProfileCard(
                        user: user,
                        server: server,
                        onSelect: { select(user) },
                        onLongPress: { forget(user) }
                    )
                    // Pre-focus the remembered default profile (or first card) so cold launch opens with a profile highlighted (issue #25).
                    .prefersDefaultFocus(isPreferredDefault(user), in: focusNamespace)
                }
            }
            Spacer(minLength: 0)
        }
        .focusSection()
    }

    private func isPreferredDefault(_ user: RememberedUser) -> Bool {
        if let defaultID = dependencies.authPreferences.defaultUserID,
           rememberedUsers.contains(where: { $0.id == defaultID }) {
            return user.id == defaultID
        }
        return user.id == rememberedUsers.first?.id
    }

    // MARK: - Add Profile

    private var addProfileButton: some View {
        Button {
            gateThenAddProfile()
        } label: {
            Label {
                Text(String(
                    localized: "profile.addAnother",
                    defaultValue: "Add another profile"
                ))
            } icon: {
                Image(systemName: "plus.circle")
            }
            .font(.body)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        // Same SettingsTileButtonStyle tint trap as ProfileSettingsView addProfileButton: default tvOS bordered style fills with tint and bleeds it into the Label; tile style keeps the label in primary foreground.
        .buttonStyle(SettingsTileButtonStyle())
    }

    // MARK: - Actions

    private func select(_ user: RememberedUser) {
        // Cold-start picker context: activating an UNPROTECTED profile
        // requires the Guardian-PIN. Protected profiles enter free.
        if dependencies.parentalGateRequired(forActivatingUserID: user.id,
                                              serverID: server.id,
                                              isColdStart: true) {
            Task {
                let unlocked = await dependencies.parentalGate.challenge(reason: .switchProfile)
                if unlocked { performSelect(user) }
            }
        } else {
            performSelect(user)
        }
    }

    private func performSelect(_ user: RememberedUser) {
        do {
            try dependencies.switchToUser(user, server: server)
            // Thumbnails fetched under the old token may no longer resolve.
            ImageCache.shared.clear()
            // FilterCache carries the previous user's library perms + watched flags; same-server switches don't bump serverDidSwitch, so clear here.
            FilterCache.shared.clearAll()
            let jf = JellyfinUser(
                id: user.id,
                name: user.name,
                serverID: server.id,
                hasPassword: nil,
                primaryImageTag: user.imageTag,
                policy: nil
            )
            appState.setAuthenticated(server: server, user: jf)

            // Restore this profile's own remembered Seerr session (else Catalog shows the "set up Seerr" empty state).
            Task { await restoreSeerrForProfile(userID: user.id, serverID: server.id) }
            // Backfill missing PrimaryImageTag + the server-side Policy block (drives the File Management gate) from /Users/Me, else the delete button stays hidden after switching back.
            Task { await refreshUserDetails(userID: user.id, serverID: server.id) }
        } catch {
            switchError = error.localizedDescription
        }
    }

    private func gateThenServerSwitch() {
        guard dependencies.parentalControlsActive() else { showServerSwitchSheet = true; return }
        Task {
            if await dependencies.parentalGate.challenge(reason: .serverManagement) {
                showServerSwitchSheet = true
            }
        }
    }

    private func gateThenAddProfile() {
        guard dependencies.parentalControlsActive() else { navigateToAddProfile = true; return }
        Task {
            if await dependencies.parentalGate.challenge(reason: .serverManagement) {
                navigateToAddProfile = true
            }
        }
    }

    private func refreshUserDetails(userID: String, serverID: String) async {
        // Fetch + persistence live in the container; this view only applies the refreshed user to AppState.
        if let fresh = await dependencies.refreshActiveUserDetails(
            expectedUserID: userID,
            serverID: serverID
        ) {
            appState.activeUser = fresh
        }
    }

    private func restoreSeerrForProfile(userID: String, serverID: String) async {
        // allowLegacyFallback mirrors AppRouter launch-restore: a pre-0.3.0 install on the picker has only the legacy global Seerr entry, else it never bridges to a scoped copy here.
        let outcome = await dependencies.syncSeerrSession(
            forJellyfinUserID: userID,
            jellyfinServerID: serverID,
            allowLegacyFallback: true
        )
        if case .connected(let server, let user) = outcome {
            appState.setSeerrConnected(server: server, user: user)
        } else {
            appState.disconnectSeerr()
        }
    }

    private func forget(_ user: RememberedUser) {
        do {
            try dependencies.forgetUser(id: user.id, serverID: server.id)
            rememberedUsers = dependencies.listRememberedUsers(serverID: server.id)

            // If the user forgot the defaultUserID, clear the default
            // so launch behavior doesn't try to restore a ghost.
            if dependencies.authPreferences.defaultUserID == user.id {
                dependencies.authPreferences.defaultUserID = nil
            }
        } catch {
            switchError = error.localizedDescription
        }
    }
}

// MARK: - Card

/// Circular avatar + name card with long-press-to-forget. Matches UserPickerCard for consistency between the two pickers.
struct RememberedProfileCard: View {
    let user: RememberedUser
    let server: JellyfinServer
    /// Marks the active session: green checkmark badge + idle ring so the current login is spottable in an otherwise-identical grid.
    var isCurrent: Bool = false
    let onSelect: () -> Void
    let onLongPress: () -> Void

    @Environment(\.dependencies) private var dependencies
    @FocusState private var isFocused: Bool

    private let diameter: CGFloat = 160

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 16) {
                avatar
                Text(user.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
        }
        // BareButtonStyle suppresses tvOS' default thick white focus halo; the avatar overlay draws our tint (or green-when-current) ring instead.
        .buttonStyle(BareButtonStyle())
        .focused($isFocused)
        // Long-press opens a context menu; tapping "Remove" is the explicit confirm against accidental deletion.
        .contextMenu {
            Button(role: .destructive, action: onLongPress) {
                Label(
                    String(localized: "profile.forget.confirm.short",
                           defaultValue: "Remove profile"),
                    systemImage: "trash"
                )
            }
        }
    }

    private var avatar: some View {
        ZStack {
            if let url = profileImageURL {
                AsyncCachedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsCircle
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            } else {
                initialsCircle
                    .frame(width: diameter, height: diameter)
            }
        }
        .overlay(
            // Green idle ring on the active profile; suppressed when focused (focus-tint ring takes over).
            Circle()
                .strokeBorder(.green, lineWidth: 4)
                .padding(-3)
                .opacity(isCurrent && !isFocused ? 0.85 : 0)
        )
        .overlay(
            Circle()
                .strokeBorder(.tint, lineWidth: 3)
                .padding(-3)
                .opacity(isFocused ? 1 : 0)
        )
        .overlay(alignment: .bottomTrailing) {
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(.black.opacity(0.6)).blur(radius: 4))
                    .offset(x: 4, y: 4)
            }
        }
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    private var initialsCircle: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Text(initials)
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private var initials: String {
        let parts = user.name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(user.name.prefix(2)).uppercased()
    }

    private var profileImageURL: URL? {
        dependencies.jellyfinImageService.userProfileImageURL(
            userID: user.id,
            tag: user.imageTag
        )
    }
}
