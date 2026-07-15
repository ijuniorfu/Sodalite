#if os(iOS)
import SwiftUI

/// Two-slot URL editor shared by Jellyfin server management and Seerr
/// settings. Saving probes the entered URLs (2 s); unreachable ones raise a
/// save-anyway confirmation instead of blocking (the user may be away from
/// the network that URL lives on).
struct DualURLEditSheet: View {
    let title: LocalizedStringKey
    let initialInternalURL: URL?
    let initialExternalURL: URL?
    let probe: @Sendable (URL) async -> Bool
    let onSave: (URL?, URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var internalText: String = ""
    @State private var externalText: String = ""
    @State private var isValidating = false
    @State private var validationError: LocalizedStringKey?
    @State private var unreachableHosts: [String] = []
    @State private var showUnreachableConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("multiServer.urls.internal.placeholder", text: $internalText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("multiServer.urls.internal", bundle: .main)
                }
                Section {
                    TextField("multiServer.urls.external.placeholder", text: $externalText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("multiServer.urls.external", bundle: .main)
                } footer: {
                    Text("multiServer.urls.footer", bundle: .main)
                }
                if let validationError {
                    Section {
                        Text(validationError, bundle: .main)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(Text(title, bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isValidating {
                        ProgressView()
                    } else {
                        Button("common.save") { Task { await validateAndSave() } }
                    }
                }
            }
            .interactiveDismissDisabled(isValidating)
            .confirmationDialog(
                Text("multiServer.urls.unreachable.title", bundle: .main),
                isPresented: $showUnreachableConfirm,
                titleVisibility: .visible
            ) {
                Button("multiServer.urls.saveAnyway") { commit() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("multiServer.urls.unreachable.message \(unreachableHosts.joined(separator: ", "))", bundle: .main)
            }
            .onAppear {
                internalText = initialInternalURL?.absoluteString ?? ""
                externalText = initialExternalURL?.absoluteString ?? ""
            }
        }
    }

    private func parsed(_ text: String) -> URL?? {
        // Outer nil: invalid input. Inner nil: intentionally empty slot.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return URL?.none }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host() != nil else { return nil }
        return url
    }

    private func validateAndSave() async {
        validationError = nil
        guard let internalURL = parsed(internalText), let externalURL = parsed(externalText) else {
            validationError = "multiServer.urls.invalid"
            return
        }
        guard internalURL != nil || externalURL != nil else {
            validationError = "multiServer.urls.atLeastOne"
            return
        }
        isValidating = true
        defer { isValidating = false }
        var dead: [String] = []
        if let internalURL, await !probe(internalURL) { dead.append(internalURL.host() ?? internalURL.absoluteString) }
        if let externalURL, await !probe(externalURL) { dead.append(externalURL.host() ?? externalURL.absoluteString) }
        if dead.isEmpty {
            commit()
        } else {
            unreachableHosts = dead
            showUnreachableConfirm = true
        }
    }

    private func commit() {
        let internalURL = (parsed(internalText) ?? nil)
        let externalURL = (parsed(externalText) ?? nil)
        onSave(internalURL, externalURL)
        dismiss()
    }
}
#endif
