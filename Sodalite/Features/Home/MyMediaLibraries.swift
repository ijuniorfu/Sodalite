import Foundation

/// Which Jellyfin views the My Media row offers, and how the tile's grid asks for their contents.
///
/// Collections and Playlists joined the video libraries here because My Media is the shortcut into
/// the server's own views, and those two are the ones a viewer asks for by name (Discord,
/// 2026-08-28). Both are views without a folder behind them, so they need a different query shape
/// than a real library, which is the part worth pinning down in tests.
enum MyMediaLibraries {
    /// Music and books stay out: neither opens into a grid this app can render.
    static let browsableCollectionTypes: Set<String> = [
        "movies", "tvshows", "homevideos", "mixed", "boxsets", "playlists",
    ]

    static func browsable(_ libraries: [JellyfinLibrary]) -> [JellyfinLibrary] {
        libraries.filter { browsableCollectionTypes.contains($0.collectionType ?? "") }
    }

    /// A view Jellyfin lists under /Users/{id}/Views without a folder id that scopes its items. Their
    /// contents answer to the type filter alone, which is how both Home rows fetch them; scoping one
    /// by parentID is what returns an empty grid.
    static func isVirtualView(_ type: LibraryType) -> Bool {
        type == .boxsets || type == .playlists
    }

    static func itemTypes(for type: LibraryType) -> [ItemType] {
        switch type {
        case .movies: [.movie]
        case .tvshows: [.series]
        case .boxsets: [.boxSet]
        case .playlists: [.playlist]
        default: [.movie, .series]
        }
    }

    /// Jellyfin answers IncludeItemTypes=Playlist with audio and video playlists alike, and a music
    /// playlist has no detail screen to open (Sodalite#73), so the playlists grid drops them.
    static func hidesAudioPlaylists(_ type: LibraryType) -> Bool {
        type == .playlists
    }
}
