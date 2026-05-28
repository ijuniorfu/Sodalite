import SwiftUI

/// Settings sub-screen for the Apple TV Profile mappings. Lists
/// every entry in TVProfileMappings.allMappings plus a synthetic
/// "current tvOS user" row when the current identifier has no
/// mapping yet. On Apple TVs without multi-user, shows a single
/// read-only "Shared session" row with an explanatory caption.
struct TVUserProfileSettingsView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var mappings: [(tvUserID: String, mapping: TVProfileMapping?)] = []
    @State private var editing: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("tvOSProfile.title", bundle: .main)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 8)

                if TVUserContext.currentUserID == nil {
                    sharedSessionRow
                } else {
                    ForEach(mappings, id: \.tvUserID) { entry in
                        TVProfileRow(
                            tvUserID: entry.tvUserID,
                            mapping: entry.mapping,
                            isCurrent: entry.tvUserID == TVUserContext.currentUserID,
                            servers: dependencies.listKnownServers(),
                            resolveProfile: { id in
                                guard let m = entry.mapping else { return nil }
                                return dependencies.listRememberedUsers(serverID: m.serverID)
                                    .first(where: { $0.id == m.jellyfinUserID })?.name
                            },
                            onEdit: { editing = entry.tvUserID },
                            onRemove: {
                                dependencies.tvProfileMappings.setMapping(nil, for: entry.tvUserID)
                                load()
                            }
                        )
                    }
                }

                Text("tvOSProfile.footer.hint", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .onAppear(perform: load)
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            if let tvUserID = editing {
                TVProfileEditSheet(
                    tvUserID: tvUserID,
                    onSave: { mapping in
                        dependencies.tvProfileMappings.setMapping(mapping, for: tvUserID)
                        editing = nil
                        load()
                    },
                    onCancel: { editing = nil }
                )
            }
        }
    }

    private var sharedSessionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "person.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("tvOSProfile.sharedSession.title", bundle: .main)
                    .font(.headline)
            }
            Text("tvOSProfile.sharedSession.caption", bundle: .main)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func load() {
        let stored = dependencies.tvProfileMappings.allMappings
        var entries: [(String, TVProfileMapping?)] = stored.map { ($0.key, $0.value) }
        if let currentID = TVUserContext.currentUserID,
           stored[currentID] == nil {
            entries.append((currentID, nil))
        }
        // Current tvOS user first, then alphabetically.
        entries.sort { lhs, rhs in
            if lhs.0 == TVUserContext.currentUserID { return true }
            if rhs.0 == TVUserContext.currentUserID { return false }
            return lhs.0 < rhs.0
        }
        mappings = entries.map { (tvUserID: $0.0, mapping: $0.1) }
    }
}

private struct TVProfileRow: View {
    let tvUserID: String
    let mapping: TVProfileMapping?
    let isCurrent: Bool
    let servers: [JellyfinServer]
    let resolveProfile: (String) -> String?
    let onEdit: () -> Void
    let onRemove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if isCurrent {
                    Text("tvOSProfile.row.current", bundle: .main)
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
                Text(tvUserIDDisplay)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let mapping {
                let serverName = servers.first(where: { $0.id == mapping.serverID })?.name
                    ?? mapping.serverID
                let profileName = resolveProfile(mapping.jellyfinUserID) ?? mapping.jellyfinUserID
                Text("tvOSProfile.row.bound \(serverName) \(profileName)", bundle: .main)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("tvOSProfile.row.unbound", bundle: .main)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused, perform: onEdit)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label {
                    Text("tvOSProfile.row.action.edit", bundle: .main)
                } icon: {
                    Image(systemName: "pencil")
                }
            }
            if mapping != nil {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label {
                        Text("tvOSProfile.row.action.remove", bundle: .main)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    /// The tvOS identifier is an opaque string. Show the first 8
    /// characters with an ellipsis so the rows are visually
    /// distinguishable without taking the whole width.
    private var tvUserIDDisplay: String {
        let prefix = tvUserID.prefix(8)
        return tvUserID.count > 8 ? "\(prefix)..." : String(prefix)
    }
}

private struct TVProfileEditSheet: View {
    let tvUserID: String
    let onSave: (TVProfileMapping) -> Void
    let onCancel: () -> Void
    @Environment(\.dependencies) private var dependencies
    @State private var selectedServerID: String?
    @State private var selectedUserID: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("tvOSProfile.editSheet.title", bundle: .main)
                .font(.title2.bold())
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(dependencies.listKnownServers()) { server in
                        let users = dependencies.listRememberedUsers(serverID: server.id)
                        ForEach(users) { user in
                            row(server: server, user: user)
                        }
                    }
                }
                .padding(.horizontal, 40)
            }
            HStack(spacing: 24) {
                Button("common.cancel") { onCancel() }
                Button("common.save") {
                    if let sid = selectedServerID, let uid = selectedUserID {
                        onSave(TVProfileMapping(serverID: sid, jellyfinUserID: uid))
                    }
                }
                .disabled(selectedServerID == nil || selectedUserID == nil)
            }
        }
        .frame(maxWidth: 900, maxHeight: 700)
        .padding(40)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row(server: JellyfinServer, user: RememberedUser) -> some View {
        Button {
            selectedServerID = server.id
            selectedUserID = user.id
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(user.name).font(.headline)
                    Text(server.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedServerID == server.id, selectedUserID == user.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(.card)
    }
}
