import SwiftUI

struct ServerDiscoveryView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel: ServerDiscoveryViewModel?

    /// If true, the post-login flow runs through addServer instead
    /// of the first-run "set as initial server" path. The completion
    /// closure is called when the user has either finished adding
    /// (success) or cancelled out (no server added).
    var addMode: Bool = false
    var onCompletion: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                VStack(spacing: 24) {
                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)

                    VStack(spacing: 8) {
                        Text("auth.server.title")
                            .font(.title2)

                        Text("auth.server.subtitle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if let vm = viewModel {
                    VStack(spacing: 20) {
                        TextField(String(localized: "auth.server.placeholder"), text: Bindable(vm).serverAddress)
                            .textFieldStyle(.automatic)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif

                        if let error = vm.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button {
                            Task { await vm.connectToServer() }
                        } label: {
                            if vm.isLoading {
                                ProgressView()
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 12)
                            } else {
                                Text("auth.server.connect")
                                    .font(.body)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 12)
                            }
                        }
                        .buttonStyle(SettingsTileButtonStyle())
                        .disabled(vm.isLoading || vm.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(maxWidth: 500)
                    .navigationDestination(isPresented: Bindable(vm).showLogin) {
                        if let server = vm.discoveredServer {
                            UserPickerView(
                                server: server,
                                addMode: addMode,
                                onCompletion: onCompletion
                            )
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .onAppear {
                if viewModel == nil {
                    viewModel = ServerDiscoveryViewModel(
                        discoveryService: dependencies.serverDiscoveryService
                    )
                }
            }
        }
    }
}
