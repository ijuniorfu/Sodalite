import SwiftUI

struct SeerrRequestEditSheet: View {
    let request: SeerrRequest
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Edit sheet placeholder, Task 12 fills this in")
                .padding()
            Button("common.cancel") { dismiss() }
        }
    }
}
