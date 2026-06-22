import Foundation

enum SeerrImageURL {
    private static let base = URL(string: "https://image.tmdb.org/t/p")!

    enum PosterSize: String {
        case w342, w500, w780, original
    }

    enum BackdropSize: String {
        case w780, w1280, original
    }

    static func poster(path: String?, size: PosterSize = .w500) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    static func backdrop(path: String?, size: BackdropSize = .w1280) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    /// TMDB duotone treatment: collapses a colour logo to white-on-grey so network/studio tiles stay consistent on dark, matching Jellyseerr's CompanyCard.
    static func duotoneLogo(path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/\(cleaned)")
    }

    enum ProfileSize: String {
        case w185, h632, original
    }

    static func profile(path: String?, size: ProfileSize = .w185) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    static func logo(path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent("w92").appendingPathComponent(cleaned)
    }
}
