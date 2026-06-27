import Foundation

enum SeerrImageURL {
    private static let base = URL(string: "https://image.tmdb.org/t/p")!

    /// Drops a non-empty TMDB path's leading slash so it can be appended as a single path component. Returns nil for nil/empty input.
    private static func cleanedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    enum PosterSize: String {
        case w342, w500, w780
    }

    enum BackdropSize: String {
        case w780, w1280
    }

    static func poster(path: String?, size: PosterSize = .w500) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    static func backdrop(path: String?, size: BackdropSize = .w1280) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    /// TMDB duotone treatment: collapses a colour logo to white-on-grey so network/studio tiles stay consistent on dark, matching Jellyseerr's CompanyCard.
    static func duotoneLogo(path: String?) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w780_filter(duotone,ffffff,bababa)/\(cleaned)")
    }

    enum ProfileSize: String {
        case w185
    }

    static func profile(path: String?, size: ProfileSize = .w185) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return base.appendingPathComponent(size.rawValue).appendingPathComponent(cleaned)
    }

    static func logo(path: String?) -> URL? {
        guard let cleaned = cleanedPath(path) else { return nil }
        return base.appendingPathComponent("w92").appendingPathComponent(cleaned)
    }
}
