import Foundation

struct JellyfinLibrary: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let collectionType: String?
    let imageTags: ImageTags?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageTags = "ImageTags"
    }

    var libraryType: LibraryType {
        guard let collectionType else { return .unknown }
        return LibraryType(rawValue: collectionType) ?? .unknown
    }
}

enum LibraryType: String, Sendable {
    case movies
    case tvshows
    case music
    case books
    case homevideos
    case boxsets
    case unknown
}

/// Decodes one item, yielding nil instead of throwing when the element is malformed (e.g. a Jellyfin
/// entry with a null Name). Jellyfin's BaseItemDto.Name is nullable, and a standard `[JellyfinItem]`
/// decode is all-or-nothing: one such item would throw and strand the entire grid or row. Decoding
/// into `[FailableJellyfinItem]` and compact-mapping keeps the rest and drops only the bad element.
struct FailableJellyfinItem: Decodable {
    let value: JellyfinItem?
    init(from decoder: Decoder) throws {
        value = try? JellyfinItem(from: decoder)
    }
}

/// A `[JellyfinItem]` for top-level array endpoints that drops elements which fail to decode rather
/// than failing the whole response.
struct LossyJellyfinItems: Decodable, Sendable {
    let elements: [JellyfinItem]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        elements = try container.decode([FailableJellyfinItem].self).compactMap(\.value)
    }
}

struct JellyfinItemsResponse: Codable, Sendable {
    let items: [JellyfinItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([FailableJellyfinItem].self, forKey: .items) ?? []
        items = raw.compactMap(\.value)
        totalRecordCount = try container.decode(Int.self, forKey: .totalRecordCount)
    }
}
