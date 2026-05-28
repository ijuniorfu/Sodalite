import SwiftUI

/// Settings sub-screen for managing knownServers. Lists every
/// server with switch (stableTap) + remove (contextMenu) actions.
/// "Server hinzufügen" at the bottom routes through the same
/// ServerDiscoveryView add-flow used by the Launch Profile Picker.
struct ServerManagementView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    @State private var servers: [JellyfinServer] = []
    @State private var activeID: String?
    @State private var showAddServerFlow = false
    @State private var pendingRemoval: JellyfinServer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("multiServer.settings.title", bundle: .main)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 8)

                ForEach(servers) { server in
                    ServerManagementRow(
                        server: server,
                        isActive: server.id == activeID,
                        userCount: dependencies.listRememberedUsers(serverID: server.id).count,
                        onSwitch: { switchTo(server) },
                        onRemove: { pendingRemoval = server }
                    )
                }

                AddServerSettingsRow(onTap: { showAddServerFlow = true })
                    .padding(.top, 16)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
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
    }

    private func load() {
        servers = dependencies.listKnownServers()
        activeID = dependencies.activeServer?.id
    }

    private func switchTo(_ server: JellyfinServer) {
        guard server.id != activeID else { return }
        try? dependencies.switchServer(to: server.id)
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
    let userCount: Int
    let onSwitch: () -> Void
    let onRemove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(server.name)
                        .font(.headline)
                    if isActive {
                        Text("multiServer.row.active", bundle: .main)
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.18), in: Capsule())
                    }
                }
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("multiServer.row.userCount \(userCount)", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(focused ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2)
        )
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused) {
            if !isActive { onSwitch() }
        }
        .contextMenu {
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
        .background(focused ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2)
        )
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}
