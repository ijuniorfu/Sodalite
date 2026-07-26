import Foundation

/// The `sodalite://` links the Top Shelf emits. `item` is the cell's displayAction (Select),
/// `play` its playAction (the remote's Play button).
struct DeepLinkRoute: Equatable {
    let itemID: String
    let autoPlay: Bool

    static func parse(_ url: URL) -> DeepLinkRoute? {
        guard url.scheme == "sodalite" else { return nil }
        let autoPlay: Bool
        switch url.host {
        case "item": autoPlay = false
        case "play": autoPlay = true
        default: return nil
        }
        let id = url.pathComponents.dropFirst().first ?? ""
        guard !id.isEmpty else { return nil }
        return DeepLinkRoute(itemID: id, autoPlay: autoPlay)
    }
}

/// What the deep-link cover presents: the fetched item together with whether it should start
/// playing. One value rather than two parallel `@State`s, so the cover can never be built from the
/// new item while still reading the previous flag.
struct DeepLinkPresentation: Identifiable {
    let item: JellyfinItem
    let autoPlay: Bool

    /// Includes autoPlay so re-opening the same item with a different intent counts as a new presentation.
    var id: String { "\(item.id)-\(autoPlay)" }
}
