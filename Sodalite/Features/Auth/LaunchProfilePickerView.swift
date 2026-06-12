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

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                header

                Button(action: { showServerSwitchSheet = true }) {
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
                .padding(.bottom, 24)

                profileGrid

                addProfileButton
                    .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationDestination(isPresented: $navigateToAddProfile) {
                // UserPickerView shows the server's public users with
                // avatars, mirrors the normal login entry point so a
                // second profile feels like "pick another user" rather
                // than "type username+password from scratch".
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
                        // Picker re-resolves the active server via the
                        // environment dependencies on next render; no
                        // explicit reload needed here.
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
                }
            }
            Spacer(minLength: 0)
        }
        .focusSection()
    }

    // MARK: - Add Profile

    private var addProfileButton: some View {
        Button {
            navigateToAddProfile = true
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
        // Same accent-tint trap as the addProfileButton on the
        // ProfileSettingsView, the default tvOS bordered style fills
        // with the active tint and propagates that tint into the
        // Label's icon + text. Tile style fills with white-opacity
        // and lets the label render in primary foreground regardless.
        .buttonStyle(SettingsTileButtonStyle())
    }

    // MARK: - Actions

    private func select(_ user: RememberedUser) {
        do {
            try dependencies.switchToUser(user, server: server)
            // Drop cached thumbnails, they were fetched under the
            // old profile's token which may no longer resolve.
            ImageCache.shared.clear()
            // Filter-grid caches carry the previous user's library
            // permissions + watched/favorite flags; same-server
            // switches never bump serverDidSwitch, so clear here.
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

            // Restore this profile's own remembered Seerr session.
            // If the target profile never signed into Seerr, Seerr
            // stays disconnected and the Catalog tab shows the "set
            // up Seerr" empty state.
            Task { await restoreSeerrForProfile(userID: user.id, serverID: server.id) }
            // Backfill a missing PrimaryImageTag AND the server-side
            // Policy block (drives the File Management permission
            // gate) from /Users/Me. Without the Policy refresh, the
            // delete button stays hidden after switching back to a
            // profile that has the right.
            Task { await refreshUserDetails(userID: user.id, serverID: server.id) }
        } catch {
            switchError = error.localizedDescription
        }
    }

    private func refreshUserDetails(userID: String, serverID: String) async {
        // Fetch + keychain/remembered-user persistence live in the
        // container; this view only applies the refreshed user to
        // AppState.
        if let fresh = await dependencies.refreshActiveUserDetails(
            expectedUserID: userID,
            serverID: serverID
        ) {
            appState.activeUser = fresh
        }
    }

    private func restoreSeerrForProfile(userID: String, serverID: String) async {
        // allowLegacyFallback matches the launch-restore path in
        // AppRouter: a pre-0.3.0 install that lands on the picker
        // (no default profile) has only the legacy global Seerr
        // entry, and without the fallback its session would never
        // bridge to a scoped copy on this path.
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

/// Circular avatar + name card with long-press-to-forget support.
/// Matches the UserPickerCard look so switching between the "server
/// public users" picker and the "remembered profiles" picker feels
/// consistent.
struct RememberedProfileCard: View {
    let user: RememberedUser
    let server: JellyfinServer
    /// Set on the card representing the active session. Surfaces a
    /// green checkmark badge on the avatar + a green idle ring so
    /// the user can spot the current login at a glance, same row
    /// of cards otherwise looks identical, and the previous
    /// "Currently signed in" / "Switch profile" split-section UI
    /// disappears in favour of a single grid.
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
        // BareButtonStyle suppresses tvOS' default thick white focus
        // halo around the card. The avatar itself draws our tint
        // (or green-when-current) ring inside its own overlay.
        .buttonStyle(BareButtonStyle())
        .focused($isFocused)
        // tvOS-native: long-pressing a focusable button opens a
        // context menu instead of firing both the primary action
        // and a secondary gesture on release. Tapping "Remove"
        // inside the menu is the explicit confirmation, one extra
        // click to protect against accidental deletion.
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
            // Subtle green idle ring on the active profile so it's
            // recognisable even before the user moves focus over it.
            // Suppressed when the user moves focus onto this card,
            // the focus-tint ring takes over.
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
