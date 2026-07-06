import SwiftUI

struct ServerDiscoveryView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel: ServerDiscoveryViewModel?
    @State private var path = NavigationPath()

    var addMode: Bool = false
    var onCompletion: (() -> Void)? = nil

    private enum Route: Hashable {
        case login(JellyfinServer)
        case manual
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 32) {
                header

                if let vm = viewModel {
                    switch vm.phase {
                    case .scanning:
                        scanning(vm)
                    case .results:
                        results(vm)
                    case .empty:
                        empty
                    }
                }

                manualButton
                    .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassBackground()
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .login(let server):
                    UserPickerView(server: server, addMode: addMode, onCompletion: onCompletion)
                case .manual:
                    ServerAddressEntryView(addMode: addMode, onCompletion: onCompletion)
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = ServerDiscoveryViewModel(
                        discovery: dependencies.serverDiscovery,
                        discoveryService: dependencies.serverDiscoveryService,
                        knownServerIDs: Set(dependencies.listKnownServers().map(\.id))
                    )
                }
                await viewModel?.scan()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 24) {
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
            VStack(spacing: 8) {
                Text("auth.discovery.title")
                    .font(.title2)
                Text("auth.server.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func scanning(_ vm: ServerDiscoveryViewModel) -> some View {
        VStack(spacing: 16) {
            serverList(vm)
            HStack(spacing: 12) {
                ProgressView()
                Text("auth.discovery.scanning")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func results(_ vm: ServerDiscoveryViewModel) -> some View {
        serverList(vm)
    }

    private var empty: some View {
        Text("auth.discovery.empty.title")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func serverList(_ vm: ServerDiscoveryViewModel) -> some View {
        VStack(spacing: 12) {
            ForEach(vm.servers) { server in
                DiscoveredServerRow(
                    server: server,
                    alreadyAdded: vm.isAlreadyAdded(server),
                    onSelect: {
                        Task {
                            if let resolved = await vm.selectServer(server) {
                                path.append(Route.login(resolved))
                            }
                        }
                    }
                )
            }
        }
        .frame(maxWidth: 600)
    }

    private var manualButton: some View {
        Button {
            path.append(Route.manual)
        } label: {
            Text("auth.discovery.manual")
                .font(.body)
                .fontWeight(.semibold)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
        }
        .buttonStyle(SettingsTileButtonStyle())
    }
}

private struct DiscoveredServerRow: View {
    let server: DiscoveredServer
    let alreadyAdded: Bool
    let onSelect: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(server.name)
                        .font(.headline)
                    if alreadyAdded {
                        Text("auth.discovery.alreadyAdded")
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.18), in: Capsule())
                    }
                }
                Text(server.address.host() ?? server.address.absoluteString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        .stableTap(isFocused: focused, perform: onSelect)
    }
}
