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
    // `var` so HomeViewModel can patch a just-watched item's resume
    // progress in place from the playback-stop payload (issue #24),
    // without waiting on a full row re-fetch to land fresh data.
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
