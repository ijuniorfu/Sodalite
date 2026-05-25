import SwiftUI

struct CatalogAllRequestsView: View {
    @Bindable var viewModel: CatalogViewModel

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
