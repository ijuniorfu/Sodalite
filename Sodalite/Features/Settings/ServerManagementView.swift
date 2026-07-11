import SwiftUI

/// Manages knownServers: switch (stableTap) + remove (contextMenu); add routes through ServerDiscoveryView.
struct ServerManagementView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    @State private var servers: [JellyfinServer] = []
    @State private var activeID: String?
    @State private var defaultID: String?
    @State private var showAddServerFlow = false
    @State private var pendingRemoval: JellyfinServer?
    @State private var showSwitchFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("multiServer.settings.title", bundle: .main)
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)

                ForEach(servers) { server in
                    let remembered = dependencies.listRememberedUsers(serverID: server.id)
                    ServerManagementRow(
                        server: server,
                        isActive: server.id == activeID,
                        isDefault: server.id == defaultID,
                        userCount: remembered.count,
                        rememberedUsers: remembered,
                        onSwitch: { switchTo(server) },
                        onRemove: { pendingRemoval = server },
                        onToggleDefault: { toggleDefault(server) }
                    )
                }

                Text("multiServer.settings.longPressHint", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                AddServerSettingsRow(onTap: { showAddServerFlow = true })
                    .padding(.top, 16)
            }
            .screenContentInset()
        }
        .onAppear(perform: load)
        .fullScreenCover(isPresented: $showAddServerFlow) {
            ServerDiscoveryView(addMode: true, onCompletion: {
                showAddServerFlow = false
                load()
            })
        }
        .alert(
            Text("multiServer.remove.confirm.title", bundle: .main),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { server in
            Button("multiServer.remove.confirm.action", role: .destructive) {
                remove(server)
            }
            Button("common.cancel", role: .cancel) {}
        } message: { server in
            Text("multiServer.remove.confirm.message \(server.name)", bundle: .main)
        }
        .alert(
            Text("multiServer.switch.failed.title", bundle: .main),
            isPresented: $showSwitchFailed
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("multiServer.switch.failed.message", bundle: .main)
        }
    }

    private func load() {
        servers = dependencies.listKnownServers()
        activeID = dependencies.activeServer?.id
        defaultID = dependencies.authPreferences.defaultServerID
    }

    private func switchTo(_ server: JellyfinServer) {
        guard server.id != activeID else { return }
        let previous = activeID
        do {
            try dependencies.switchServer(to: server.id)
        } catch {
            // switchServer writes the active-server pointer BEFORE it can throw (.missingToken) -> half-switched broken session; roll back like ServerSwitchSheet.
            if let previous {
                try? dependencies.rollbackSwitch(to: previous)
            }
            showSwitchFailed = true
        }
        load()
    }

    private func toggleDefault(_ server: JellyfinServer) {
        if dependencies.authPreferences.defaultServerID == server.id {
            dependencies.authPreferences.defaultServerID = nil
        } else {
            dependencies.authPreferences.defaultServerID = server.id
        }
        load()
    }

    private func remove(_ server: JellyfinServer) {
        try? dependencies.removeServer(id: server.id)
        load()
    }
}

private struct ServerManagementRow: View {
    let server: JellyfinServer
    let isActive: Bool
    let isDefault: Bool
    let userCount: Int
    let rememberedUsers: [RememberedUser]
    let onSwitch: () -> Void
    let onRemove: () -> Void
    let onToggleDefault: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isActive {
                        Text("multiServer.row.active", bundle: .main)
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .fixedSize()
                    }
                    if isDefault {
                        Text("multiServer.row.default", bundle: .main)
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .fixedSize()
                    }
                }
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("multiServer.row.userCount \(userCount)", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            if !rememberedUsers.isEmpty {
                HStack(spacing: -10) {
                    ForEach(rememberedUsers.prefix(3)) { user in
                        avatarCircle(for: user)
                    }
                    if rememberedUsers.count > 3 {
                        ZStack {
                            Circle()
                                .fill(.regularMaterial)
                                .frame(width: 40, height: 40)
                            Text("+\(rememberedUsers.count - 3)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(focused ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 6)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .stableTap(isFocused: focused) {
            if !isActive { onSwitch() }
        }
        .contextMenu {
            Button {
                onToggleDefault()
            } label: {
                Label {
                    Text(isDefault
                         ? "multiServer.row.action.unsetDefault"
                         : "multiServer.row.action.setDefault",
                         bundle: .main)
                } icon: {
                    Image(systemName: isDefault ? "star.slash" : "star")
                }
            }
            if !isActive {
                Button {
                    onSwitch()
                } label: {
                    Label {
                        Text("multiServer.row.action.switch", bundle: .main)
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                }
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label {
                    Text("multiServer.row.action.remove", bundle: .main)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func avatarCircle(for user: RememberedUser) -> some View {
        let url = dependencies.jellyfinImageService.userProfileImageURL(
            userID: user.id,
            tag: user.imageTag
        )
        ZStack {
            if let url {
                AsyncCachedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsFallback(for: user)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                initialsFallback(for: user)
            }
        }
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 2)
        )
    }

    private func initialsFallback(for user: RememberedUser) -> some View {
        let initials: String = {
            let parts = user.name.split(separator: " ")
            if parts.count >= 2 {
                return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
            }
            return String(user.name.prefix(2)).uppercased()
        }()
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 40, height: 40)
            Text(initials)
                .font(.caption.bold())
                .foregroundStyle(.primary)
        }
    }
}

private struct AddServerSettingsRow: View {
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("multiServer.settings.add", bundle: .main)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(focused ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 6)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}
