import Foundation

/// Subset of Jellyfin's item DTO the TopShelf renders; PascalCase keys so the same JSON the main app receives decodes here unmassaged.
struct JellyfinItem: Decodable, Sendable {
    let id: String
    let name: String
    let type: ItemType
    let seriesName: String?
    let seriesId: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let imageTags: ImageTags?
    let backdropImageTags: [String]?
    let parentBackdropImageTags: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropImageTags = "ParentBackdropImageTags"
    }
}

enum ItemType: String, Decodable, Sendable {
    case movie = "Movie"
    case series = "Series"
    case episode = "Episode"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemType(rawValue: raw) ?? .unknown
    }
}

struct ImageTags: Decodable, Sendable {
    let primary: String?
    let thumb: String?

    enum CodingKeys: String, CodingKey {
        case primary = "Primary"
        case thumb = "Thumb"
    }
}

extension JellyfinItem {
    /// Wide thumbnail for the carousel cell: episodes prefer their own Primary still (parent series backdrop fallback for orphans), movies use their backdrop. Episode resolution is capped at the server's image-extraction-width setting (320 old default, can't upscale client-side); requests enableImageEnhancers=false to dodge a downscaling enhancer.
    func topShelfImageURL(baseURL: URL, token: String) -> URL? {
        if type == .episode {
            if let tag = imageTags?.primary {
                return imageURL(baseURL: baseURL, itemID: id, kind: "Primary", tag: tag, token: token)
            }
            if let tag = imageTags?.thumb {
                return imageURL(baseURL: baseURL, itemID: id, kind: "Thumb", tag: tag, token: token)
            }
            if let seriesId, let tag = parentBackdropImageTags?.first {
                return imageURL(baseURL: baseURL, itemID: seriesId, kind: "Backdrop", tag: tag, token: token)
            }
        }
        if let tag = backdropImageTags?.first {
            return imageURL(baseURL: baseURL, itemID: id, kind: "Backdrop", tag: tag, token: token)
        }
        if let tag = imageTags?.primary {
            return imageURL(baseURL: baseURL, itemID: id, kind: "Primary", tag: tag, token: token)
        }
        return nil
    }

    /// Card headline: movies render bare name; episodes prefix series + S/E breadcrumb (the still alone doesn't identify the show).
    var topShelfTitle: String {
        guard type == .episode, let series = seriesName else { return name }
        if let s = parentIndexNumber, let e = indexNumber {
            return "\(series) · S\(s)E\(e) · \(name)"
        }
        return "\(series) · \(name)"
    }

    /// format=Jpg so the image-cache daemon never hits a WebP/AVIF response ImageIO can choke on in the tight extension budget. maxWidth=1280 covers Apple TV 4K (cells ~820px@2x + focus-zoom). enableImageEnhancers=false skips a downscaling server transform; quality=100 avoids stacking JPEG loss on an already-thumbnail episode still.
    private func imageURL(baseURL: URL, itemID: String, kind: String, tag: String, token: String) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let raw = "\(base)/Items/\(itemID)/Images/\(kind)?tag=\(tag)&maxWidth=1280&quality=100&format=Jpg&enableImageEnhancers=false&api_key=\(token)"
        return URL(string: raw)
    }
}
