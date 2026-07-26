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
