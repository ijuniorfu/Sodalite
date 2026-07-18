#if os(iOS)
import SwiftUI

/// Single-field URL sheet shown after login to add the missing internal/external
/// address. Mirrors DualURLEditSheet's parse + probe + save-anyway behavior but
/// for exactly one slot; the already-known address is shown read-only for context.
struct AddSecondURLSheet: View {
    let slot: ServerRoute
    let knownURL: URL
    let probe: @Sendable (URL) async -> Bool
    let onSave: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var isValidating = false
    @State private var validationError: LocalizedStringKey?
    @State private var showUnreachableConfirm = false
    @State private var unreachableHost = ""

    private var title: LocalizedStringKey {
        slot == .internal ? "multiServer.addURL.sheet.title.internal" : "multiServer.addURL.sheet.title.external"
    }
    private var placeholder: LocalizedStringKey {
        slot == .internal ? "multiServer.urls.internal.placeholder" : "multiServer.urls.external.placeholder"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(knownURL.host() ?? knownURL.absoluteString)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("multiServer.addURL.knownLabel", bundle: .main)
                    }
                }
                Section {
                    TextField(placeholder, text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isValidating)
                } footer: {
                    Text("multiServer.addURL.footer", bundle: .main)
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
                Text("multiServer.urls.unreachable.message \(unreachableHost)", bundle: .main)
            }
        }
    }

    private func parsed() -> URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host() != nil else { return nil }
        return url
    }

    private func validateAndSave() async {
        validationError = nil
        guard let url = parsed() else {
            validationError = "multiServer.urls.invalid"
            return
        }
        isValidating = true
        defer { isValidating = false }
        if await probe(url) {
            commit()
        } else {
            unreachableHost = url.host() ?? url.absoluteString
            showUnreachableConfirm = true
        }
    }

    private func commit() {
        guard let url = parsed() else { return }
        onSave(url)
        dismiss()
    }
}
#endif
