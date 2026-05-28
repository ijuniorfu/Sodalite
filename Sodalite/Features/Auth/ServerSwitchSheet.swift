import SwiftUI

/// Modal sheet for picking among `knownServers` or adding a new one.
/// Presented from `LaunchProfilePickerView` (server header card)
/// and from `ServerManagementView` (Settings) for the same purpose.
struct ServerSwitchSheet: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    /// Called after the user picks "Neuer Server". The host view
    /// is expected to push or fullScreenCover a ServerDiscoveryView
    /// configured in add-mode.
    let onAddServer: () -> Void

    /// Called after the user has picked a different server and the
    /// switch has been attempted. The bool indicates whether the
    /// switch succeeded. The host uses this to react (e.g. dismiss
    /// the picker for a successful switch, show a toast on failure).
    let onSwitched: (Bool) -> Void

    @State private var servers: [JellyfinServer] = []
    @State private var activeID: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("multiServer.switchSheet.title", bundle: .main)
                .font(.title2.bold())
                .foregroundStyle(.primary)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(servers) { server in
                        ServerRow(
                            server: server,
                            isActive: server.id == activeID,
                            onTap: { switchTo(server) }
                        )
                    }
                    AddServerRow(onTap: {
                        dismiss()
                        onAddServer()
                    })
                }
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: 900, maxHeight: 700)
        .padding(40)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear(perform: load)
    }

    private func load() {
        servers = dependencies.listKnownServers()
        activeID = dependencies.activeServer?.id
    }

    private func switchTo(_ server: JellyfinServer) {
        if server.id == activeID {
            dismiss()
            return
        }
        let previous = activeID
        do {
            try dependencies.switchServer(to: server.id)
            onSwitched(true)
            dismiss()
        } catch {
            // Switch failed at the container layer (missing token /
            // unknown id). Roll back if we had a previous active
            // server, so the user isn't stranded.
            if let previous {
                try? dependencies.rollbackSwitch(to: previous)
            }
            onSwitched(false)
            dismiss()
        }
    }
}

private struct ServerRow: View {
    let server: JellyfinServer
    let isActive: Bool
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("multiServer.row.active", bundle: .main)
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(focused ? Color.white.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}

private struct AddServerRow: View {
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("multiServer.row.add", bundle: .main)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(focused ? Color.white.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}
