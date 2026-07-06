import SwiftUI

struct ServerDiscoveryView: View {
    var addMode: Bool = false
    var onCompletion: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ServerAddressEntryView(addMode: addMode, onCompletion: onCompletion)
        }
    }
}
