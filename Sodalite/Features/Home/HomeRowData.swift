import SwiftUI

enum HomeSection: Identifiable {
    case media(HomeRowData)
    case tags(HomeTagRowData)
    case discoverProviders
    case libraries([JellyfinLibrary])

    var id: String {
        switch self {
        case .media(let data): data.id
        case .tags(let data): data.id
        case .discoverProviders: "discoverProviders"
        case .libraries: "myMedia"
        }
    }
}

struct HomeRowData: Identifiable, Sendable {
    let type: HomeRowType
    // `var` so HomeViewModel can patch resume progress in place from the playback-stop payload without a full row re-fetch (issue #24).
    var items: [JellyfinItem]
    var libraryID: String? = nil
    var libraryName: String? = nil

    var id: String {
        if type == .libraryLatest, let libraryID {
            return "libraryLatest:\(libraryID)"
        }
        return type.rawValue
    }
}

struct HomeTagRowData: Identifiable, Sendable {
    let type: HomeRowType
    let tags: [TagCardData]

    var id: String { type.rawValue }
}
