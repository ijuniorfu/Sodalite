import Foundation

enum ImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
    case logo = "Logo"
    case banner = "Banner"
}

final class JellyfinImageService {
    private let baseURL: () -> URL?
    private let accessToken: () -> String?

    init(
        baseURLProvider: @escaping () -> URL?,
        accessTokenProvider: @escaping () -> String? = { nil }
    ) {
        self.baseURL = baseURLProvider
        self.accessToken = accessTokenProvider
    }

    func imageURL(
        itemID: String,
        imageType: ImageType = .primary,
        tag: String? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil
    ) -> URL? {
        guard let base = baseURL() else { return nil }
        return Self.buildURL(
            base: base,
            path: "/Items/\(itemID)/Images/\(imageType.rawValue)",
            tag: tag,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            token: accessToken()
        )
    }

    /// Manual concat (not "\(base)") so a trailing-slash baseURL doesn't double-slash (some proxies reject it); threads the token through both `api_key` (classic) and `ApiKey` (10.9+) for version coverage.
    private static func buildURL(
        base: URL,
        path: String,
        tag: String?,
        maxWidth: Int?,
        maxHeight: Int?,
        token: String?
    ) -> URL? {
        var baseString = base.absoluteString
        while baseString.hasSuffix("/") { baseString.removeLast() }
        let leadingPath = path.hasPrefix("/") ? path : "/\(path)"

        var queryItems: [String] = []
        if let tag { queryItems.append("tag=\(tag)") }
        if let maxWidth { queryItems.append("maxWidth=\(maxWidth)") }
        if let maxHeight { queryItems.append("maxHeight=\(maxHeight)") }
        queryItems.append("quality=90")
        if let token {
            queryItems.append("api_key=\(token)")
            queryItems.append("ApiKey=\(token)")
        }

        var raw = baseString + leadingPath
        if !queryItems.isEmpty {
            raw += "?" + queryItems.joined(separator: "&")
        }
        return URL(string: raw)
    }

    func backdropURL(for item: JellyfinItem, maxWidth: Int = 1920) -> URL? {
        if let tags = item.backdropImageTags, let tag = tags.first {
            return imageURL(itemID: item.id, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return imageURL(itemID: seriesId, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    /// Episode thumbnail fallback chain: own primary → own thumb → own backdrop → series backdrop → series poster.
    func episodeThumbnailURL(for item: JellyfinItem, maxWidth: Int = 640) -> URL? {
        if let tag = item.imageTags?.primary {
            return imageURL(itemID: item.id, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        if let tag = item.imageTags?.thumb {
            return imageURL(itemID: item.id, imageType: .thumb, tag: tag, maxWidth: maxWidth)
        }
        if let tags = item.backdropImageTags, let tag = tags.first {
            return imageURL(itemID: item.id, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return imageURL(itemID: seriesId, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        if item.type == .episode, let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemID: seriesId, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    func posterURL(for item: JellyfinItem, maxWidth: Int = 400) -> URL? {
        if let tag = item.imageTags?.primary {
            return imageURL(itemID: item.id, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        if item.type == .episode, let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemID: seriesId, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    /// Music cover: album primary image else the item's own poster.
    func musicCoverURL(for item: JellyfinItem, maxWidth: Int = 400) -> URL? {
        if let albumID = item.albumId, let albumTag = item.albumPrimaryImageTag {
            return imageURL(itemID: albumID, imageType: .primary, tag: albumTag, maxWidth: maxWidth)
        }
        return posterURL(for: item, maxWidth: maxWidth)
    }

    func personImageURL(personID: String, tag: String?, maxWidth: Int = 200) -> URL? {
        guard let base = baseURL(), let tag else { return nil }
        return Self.buildURL(
            base: base,
            path: "/Items/\(personID)/Images/Primary",
            tag: tag,
            maxWidth: maxWidth,
            maxHeight: nil,
            token: accessToken()
        )
    }

    /// User avatar under `/Users/{id}/Images/Primary` (vs items' `/Items` prefix). Nil when no avatar so the UI falls back to initials.
    func userProfileImageURL(userID: String, tag: String?, maxWidth: Int = 240) -> URL? {
        guard let base = baseURL(), let tag else { return nil }
        return Self.buildURL(
            base: base,
            path: "/Users/\(userID)/Images/Primary",
            tag: tag,
            maxWidth: maxWidth,
            maxHeight: nil,
            token: accessToken()
        )
    }

}
